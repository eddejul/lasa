// Läsa för Windows. Rust-delen är liten med flit: den läser ordboken, sparar användarens data och
// bokfilerna. Uppslagslogiken, läsarna och ordrutan ligger i JavaScript under ../src, så att de kan
// provas i en vanlig webbläsare (se ../dev/server.py, som svarar på samma kommandon).
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, MutexGuard};

use rusqlite::types::{Value as SqlValue, ValueRef};
use rusqlite::{params_from_iter, Connection, OpenFlags};
use serde_json::Value;
use tauri::ipc::{InvokeBody, Request, Response};
use tauri::path::BaseDirectory;
use tauri::{Manager, State};

struct AppState {
    /// Ordboken (lasa-ordbok.sqlite bland appens resurser), skrivskyddad. Felet sparas om den saknas.
    dictionary: Result<Mutex<Connection>, String>,
    /// Sparade ord och dolda synonympar (anvandarord.sqlite i appens datamapp).
    words: Mutex<Connection>,
    /// Biblioteket, läspositioner och inställningar (bibliotek.sqlite i appens datamapp).
    library: Mutex<Connection>,
    /// Mappen med bokfilerna, en fil per bok med namnet <sha256>.<filändelse>.
    books: PathBuf,
}

fn lock(mutex: &Mutex<Connection>) -> MutexGuard<'_, Connection> {
    mutex.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn to_sql(value: &Value) -> SqlValue {
    match value {
        Value::Null => SqlValue::Null,
        Value::Bool(flag) => SqlValue::Integer(i64::from(*flag)),
        Value::Number(number) => match number.as_i64() {
            Some(integer) => SqlValue::Integer(integer),
            None => SqlValue::Real(number.as_f64().unwrap_or(0.0)),
        },
        Value::String(text) => SqlValue::Text(text.clone()),
        other => SqlValue::Text(other.to_string()),
    }
}

fn from_sql(value: ValueRef<'_>) -> Value {
    match value {
        ValueRef::Null => Value::Null,
        ValueRef::Integer(integer) => Value::from(integer),
        ValueRef::Real(real) => serde_json::Number::from_f64(real)
            .map(Value::Number)
            .unwrap_or(Value::Null),
        ValueRef::Text(text) => Value::String(String::from_utf8_lossy(text).into_owned()),
        ValueRef::Blob(_) => Value::Null,
    }
}

/// Kör en fråga med parametrar och ger raderna som listor, kolumnerna i frågans ordning.
fn run_query(
    connection: &Connection,
    sql: &str,
    params: &[Value],
    read_only: bool,
) -> Result<Vec<Vec<Value>>, String> {
    let mut statement = connection
        .prepare_cached(sql)
        .map_err(|error| error.to_string())?;
    if read_only && !statement.readonly() {
        return Err("Ordboken tar bara emot frågor som läser.".to_string());
    }
    let columns = statement.column_count();
    let values: Vec<SqlValue> = params.iter().map(to_sql).collect();
    let mut rows = statement
        .query(params_from_iter(values.iter()))
        .map_err(|error| error.to_string())?;
    let mut result = Vec::new();
    while let Some(row) = rows.next().map_err(|error| error.to_string())? {
        let mut item = Vec::with_capacity(columns);
        for index in 0..columns {
            item.push(from_sql(row.get_ref(index).map_err(|error| error.to_string())?));
        }
        result.push(item);
    }
    Ok(result)
}

fn user_db<'a>(state: &'a AppState, name: &str) -> Result<&'a Mutex<Connection>, String> {
    match name {
        "ord" => Ok(&state.words),
        "bibliotek" => Ok(&state.library),
        _ => Err(format!("Okänd databas: {name}")),
    }
}

/// En SELECT-fråga mot ordboken. Bara läsande frågor går igenom, och filen är öppnad skrivskyddad.
#[tauri::command(async)]
fn dict_query(
    state: State<'_, AppState>,
    sql: String,
    params: Vec<Value>,
) -> Result<Vec<Vec<Value>>, String> {
    let dictionary = state
        .dictionary
        .as_ref()
        .map_err(|error| format!("Ordboken kunde inte öppnas: {error}"))?;
    run_query(&lock(dictionary), &sql, &params, true)
}

#[tauri::command(async)]
fn user_query(
    state: State<'_, AppState>,
    db: String,
    sql: String,
    params: Vec<Value>,
) -> Result<Vec<Vec<Value>>, String> {
    let connection = lock(user_db(&state, &db)?);
    run_query(&connection, &sql, &params, false)
}

#[tauri::command(async)]
fn user_execute(
    state: State<'_, AppState>,
    db: String,
    sql: String,
    params: Vec<Value>,
) -> Result<usize, String> {
    let connection = lock(user_db(&state, &db)?);
    let values: Vec<SqlValue> = params.iter().map(to_sql).collect();
    connection
        .execute(&sql, params_from_iter(values.iter()))
        .map_err(|error| error.to_string())
}

#[tauri::command(async)]
fn user_batch(state: State<'_, AppState>, db: String, sql: String) -> Result<(), String> {
    let connection = lock(user_db(&state, &db)?);
    connection
        .execute_batch(&sql)
        .map_err(|error| error.to_string())
}

fn book_path(state: &AppState, id: &str, ext: &str) -> Result<PathBuf, String> {
    let valid_id = id.len() == 64 && id.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'));
    let valid_ext = matches!(ext, "pdf" | "epub" | "txt" | "md");
    if !valid_id || !valid_ext {
        return Err("Ogiltigt namn på bokfilen.".to_string());
    }
    Ok(state.books.join(format!("{id}.{ext}")))
}

fn header(request: &Request<'_>, name: &str) -> Result<String, String> {
    request
        .headers()
        .get(name)
        .and_then(|value| value.to_str().ok())
        .map(|value| value.to_string())
        .ok_or_else(|| format!("{name} saknas"))
}

/// Skriver en fil säkert: först till en tillfällig fil bredvid, som byter namn när allt är skrivet och
/// sparat på disken. En krasch mitt i lämnar då aldrig en halv fil med det riktiga namnet.
fn write_atomic(path: &Path, bytes: &[u8]) -> Result<(), String> {
    let mut temporary = path.as_os_str().to_owned();
    temporary.push(".tmp");
    let temporary = PathBuf::from(temporary);
    let result = (|| -> std::io::Result<()> {
        let mut file = fs::File::create(&temporary)?;
        file.write_all(bytes)?;
        file.sync_all()?;
        drop(file);
        fs::rename(&temporary, path)
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result.map_err(|error| error.to_string())
}

/// Tillfälliga filer som blev kvar efter en krasch tas bort när appen startar.
fn remove_leftovers(books: &Path) {
    if let Ok(entries) = fs::read_dir(books) {
        for entry in entries.flatten() {
            let path = entry.path();
            if path.extension().is_some_and(|ext| ext == "tmp") {
                let _ = fs::remove_file(path);
            }
        }
    }
}

/// Sparar en bokfil. Filen kommer som råa byte, id (sha256) och filändelse i rubrikerna x-id och x-ext.
/// Körs utanför fönstrets huvudtråd, som de andra kommandona med (async), så att fönstret inte fryser.
#[tauri::command(async)]
fn library_store(state: State<'_, AppState>, request: Request<'_>) -> Result<(), String> {
    let InvokeBody::Raw(bytes) = request.body() else {
        return Err("Filen kom inte fram.".to_string());
    };
    let id = header(&request, "x-id")?;
    let ext = header(&request, "x-ext")?;
    let path = book_path(&state, &id, &ext)?;
    write_atomic(&path, bytes)
}

/// Läser en bokfil och skickar den som råa byte (en ArrayBuffer i JavaScript).
#[tauri::command(async)]
fn library_read(state: State<'_, AppState>, id: String, ext: String) -> Result<Response, String> {
    let path = book_path(&state, &id, &ext)?;
    let bytes = fs::read(&path).map_err(|error| error.to_string())?;
    Ok(Response::new(bytes))
}

#[tauri::command(async)]
fn library_delete(state: State<'_, AppState>, id: String, ext: String) -> Result<(), String> {
    let path = book_path(&state, &id, &ext)?;
    match fs::remove_file(&path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error.to_string()),
    }
}

/// Hemligheterna för synken ligger i Windows Autentiseringshanteraren, aldrig i en fil.
/// Bara de här namnen går att läsa och skriva.
const SECRET_SERVICE: &str = "se.edvin.lasa";
const SECRET_NAMES: [&str; 2] = ["sync-publishable-key", "sync-refresh-token"];

fn secret_entry(name: &str) -> Result<keyring::Entry, String> {
    if !SECRET_NAMES.contains(&name) {
        return Err(format!("Okänd hemlighet: {name}"));
    }
    keyring::Entry::new(SECRET_SERVICE, name).map_err(|error| error.to_string())
}

#[tauri::command(async)]
fn secret_get(name: String) -> Result<Option<String>, String> {
    match secret_entry(&name)?.get_password() {
        Ok(value) => Ok(Some(value)),
        Err(keyring::Error::NoEntry) => Ok(None),
        Err(error) => Err(error.to_string()),
    }
}

/// Sparar en hemlighet, eller tar bort den när värdet är tomt eller saknas.
#[tauri::command(async)]
fn secret_set(name: String, value: Option<String>) -> Result<(), String> {
    let entry = secret_entry(&name)?;
    match value {
        Some(text) if !text.is_empty() => entry.set_password(&text).map_err(|error| error.to_string()),
        _ => match entry.delete_credential() {
            Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
            Err(error) => Err(error.to_string()),
        },
    }
}

fn open_dictionary(app: &tauri::App) -> Result<Mutex<Connection>, String> {
    let path = app
        .path()
        .resolve("lasa-ordbok.sqlite", BaseDirectory::Resource)
        .map_err(|error| error.to_string())?;
    let connection = Connection::open_with_flags(
        &path,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .map_err(|error| format!("{}: {error}", path.display()))?;
    connection
        .execute_batch("PRAGMA query_only = ON;")
        .map_err(|error| error.to_string())?;
    Ok(Mutex::new(connection))
}

fn main() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .setup(|app| {
            let data = app.path().app_data_dir()?;
            let books = data.join("Böcker");
            fs::create_dir_all(&books)?;
            remove_leftovers(&books);
            let words = Connection::open(data.join("anvandarord.sqlite"))?;
            let library = Connection::open(data.join("bibliotek.sqlite"))?;
            let dictionary = open_dictionary(app);
            app.manage(AppState {
                dictionary,
                words: Mutex::new(words),
                library: Mutex::new(library),
                books,
            });
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            dict_query,
            user_query,
            user_execute,
            user_batch,
            library_store,
            library_read,
            library_delete,
            secret_get,
            secret_set
        ])
        .run(tauri::generate_context!())
        .expect("Läsa kunde inte starta");
}
