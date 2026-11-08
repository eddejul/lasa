// Läsa för Windows. Rust-delen är liten med flit: den läser ordboken, sparar användarens data och
// bokfilerna. Uppslagslogiken, läsarna och ordrutan ligger i JavaScript under ../src, så att de kan
// provas i en vanlig webbläsare (se ../dev/server.py, som svarar på samma kommandon).
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::collections::HashMap;
use std::fs;
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, MutexGuard};

use rusqlite::types::{Value as SqlValue, ValueRef};
use rusqlite::{params_from_iter, Connection, OpenFlags};
use serde_json::Value;
use tauri::ipc::{InvokeBody, Request, Response};
use tauri::path::BaseDirectory;
use tauri::webview::PageLoadEvent;
use tauri::{AppHandle, Emitter, Manager, State};

struct AppState {
    /// Ordboken (lasa-ordbok.sqlite bland appens resurser), skrivskyddad. Felet sparas om den saknas.
    dictionary: Result<Mutex<Connection>, String>,
    /// Sparade ord och dolda synonympar (anvandarord.sqlite i appens datamapp).
    words: Mutex<Connection>,
    /// Biblioteket, läspositioner och inställningar (bibliotek.sqlite i appens datamapp).
    library: Mutex<Connection>,
    /// Mappen med bokfilerna, en fil per bok med namnet <sha256>.<filändelse>.
    books: PathBuf,
    /// De namngivna frågorna mot användarens databaser (statements.json).
    statements: Statements,
    /// Fel när tabellerna skapades vid start. Då svarar db_read och db_write med felet.
    store_error: Option<String>,
}

// Smalare behörigheter (W12): gränssnittet kan bara ställa de namngivna frågorna i statements.json mot
// användarens databaser, aldrig egen SQL. Filen byggs in i appen och läses också av dev/server.py.
const STATEMENTS: &str = include_str!("../statements.json");

/// Frågornas namn, med databas och SQL. read är frågor som bara läser, write ändrar.
struct Statements {
    read: HashMap<String, (String, String)>,
    write: HashMap<String, (String, String)>,
}

fn named_statements(all: &Value, key: &str) -> HashMap<String, (String, String)> {
    let mut map = HashMap::new();
    if let Some(object) = all.get(key).and_then(Value::as_object) {
        for (name, pair) in object {
            if let (Some(db), Some(sql)) = (pair.get(0).and_then(Value::as_str), pair.get(1).and_then(Value::as_str)) {
                map.insert(name.clone(), (db.to_string(), sql.to_string()));
            }
        }
    }
    map
}

/// Skapar tabellerna och lägger till kolumner som saknas, så att en databas från en äldre version fungerar.
/// Tabell- och kolumnnamnen kommer bara från statements.json i appen, aldrig från gränssnittet.
fn migrate(connection: &Connection, database: &Value) -> Result<(), String> {
    let schema: Vec<&str> = database
        .get("schema")
        .and_then(Value::as_array)
        .map(|lines| lines.iter().filter_map(Value::as_str).collect())
        .unwrap_or_default();
    connection
        .execute_batch(&schema.join("\n"))
        .map_err(|error| error.to_string())?;
    if let Some(tables) = database.get("columns").and_then(Value::as_object) {
        for (table, columns) in tables {
            let existing: Vec<String> = {
                let mut statement = connection
                    .prepare(&format!("PRAGMA table_info({table})"))
                    .map_err(|error| error.to_string())?;
                let names = statement
                    .query_map([], |row| row.get::<_, String>(1))
                    .map_err(|error| error.to_string())?;
                let collected: Vec<String> = names.filter_map(Result::ok).collect();
                collected
            };
            for column in columns.as_array().into_iter().flatten() {
                let (Some(name), Some(definition)) =
                    (column.get(0).and_then(Value::as_str), column.get(1).and_then(Value::as_str))
                else {
                    continue;
                };
                if !existing.iter().any(|known| known == name) {
                    connection
                        .execute_batch(&format!("ALTER TABLE {table} ADD COLUMN {name} {definition}"))
                        .map_err(|error| error.to_string())?;
                }
            }
        }
    }
    Ok(())
}

/// Engångsflyttar (moves i statements.json, G3). Finns rader att flytta görs först en kopia av databasfilen
/// i datamappen, sedan körs stegen i en transaktion. Stegen går att köra om utan skada, så en flytt som
/// avbryts görs om nästa gång appen startar. Går flytten inte fungerar appen ändå (med de gamla id:na).
fn run_moves(connection: &Connection, database: &Value, folder: &Path) -> Result<(), String> {
    for item in database.get("moves").and_then(Value::as_array).into_iter().flatten() {
        let (Some(pending), Some(backup)) = (
            item.get("pending").and_then(Value::as_str),
            item.get("backup").and_then(Value::as_str),
        ) else {
            continue;
        };
        let count: i64 = connection
            .query_row(pending, [], |row| row.get(0))
            .map_err(|error| error.to_string())?;
        if count == 0 {
            continue;
        }
        let seconds = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|duration| duration.as_secs())
            .unwrap_or(0);
        let mut copy = folder.join(format!("{backup} {seconds}.sqlite"));
        let mut extra = 2;
        while copy.exists() {
            copy = folder.join(format!("{backup} {seconds} {extra}.sqlite"));
            extra += 1;
        }
        connection
            .execute("VACUUM INTO ?1", [copy.to_string_lossy().to_string()])
            .map_err(|error| format!("kopian före flytten: {error}"))?;
        let transaction = connection.unchecked_transaction().map_err(|error| error.to_string())?;
        for step in item.get("steps").and_then(Value::as_array).into_iter().flatten().filter_map(Value::as_str) {
            transaction.execute_batch(step).map_err(|error| error.to_string())?;
        }
        transaction.commit().map_err(|error| error.to_string())?;
    }
    Ok(())
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

/// En namngiven fråga som läser ur användarens databaser (statements.json, read).
#[tauri::command(async)]
fn db_read(state: State<'_, AppState>, name: String, params: Vec<Value>) -> Result<Vec<Vec<Value>>, String> {
    if let Some(error) = &state.store_error {
        return Err(error.clone());
    }
    let (db, sql) = state
        .statements
        .read
        .get(&name)
        .ok_or_else(|| format!("Okänd fråga: {name}"))?;
    let connection = lock(user_db(&state, db)?);
    run_query(&connection, sql, &params, true)
}

/// En namngiven fråga som ändrar i användarens databaser (statements.json, write). Ger antalet ändrade rader.
#[tauri::command(async)]
fn db_write(state: State<'_, AppState>, name: String, params: Vec<Value>) -> Result<usize, String> {
    if let Some(error) = &state.store_error {
        return Err(error.clone());
    }
    let (db, sql) = state
        .statements
        .write
        .get(&name)
        .ok_or_else(|| format!("Okänd ändring: {name}"))?;
    let connection = lock(user_db(&state, db)?);
    let values: Vec<SqlValue> = params.iter().map(to_sql).collect();
    connection
        .execute(sql, params_from_iter(values.iter()))
        .map_err(|error| error.to_string())
}

fn book_path(state: &AppState, id: &str, ext: &str) -> Result<PathBuf, String> {
    let valid_id = id.len() == 64 && id.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'));
    let valid_ext = matches!(ext, "pdf" | "epub" | "txt" | "md" | "rtf" | "html");
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

/// Storleken på en bokfil i byte, för läsning i bitar.
#[tauri::command(async)]
fn library_size(state: State<'_, AppState>, id: String, ext: String) -> Result<u64, String> {
    let path = book_path(&state, &id, &ext)?;
    fs::metadata(&path).map(|metadata| metadata.len()).map_err(|error| error.to_string())
}

/// En bit av en bokfil, från start till (men inte med) end, som råa byte. Stora PDF:er läses så, bit för
/// bit när pdf.js behöver dem (W4), i stället för att hela filen ligger i minnet. Högst 64 MB per bit.
#[tauri::command(async)]
fn library_read_range(state: State<'_, AppState>, id: String, ext: String, start: u64, end: u64) -> Result<Response, String> {
    let path = book_path(&state, &id, &ext)?;
    let mut file = fs::File::open(&path).map_err(|error| error.to_string())?;
    let length = end.saturating_sub(start).min(64 * 1024 * 1024);
    file.seek(SeekFrom::Start(start)).map_err(|error| error.to_string())?;
    let mut bytes = Vec::with_capacity(length as usize);
    file.take(length).read_to_end(&mut bytes).map_err(|error| error.to_string())?;
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

/// Hemligheterna för synken och AI-knappen ligger i Windows Autentiseringshanteraren, aldrig i en fil.
/// Bara de här namnen går att läsa och skriva.
const SECRET_SERVICE: &str = "se.edvin.lasa";
// gemini-api-key: nyckeln till AI-knappen (W11).
const SECRET_NAMES: [&str; 3] = ["sync-publishable-key", "sync-refresh-token", "gemini-api-key"];

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
    // Filen läses via minnesavbildning (128 MB räcker för hela ordboken), så att uppslagen inte behöver
    // läsa från disken var för sig. Gränssnittet slår upp några ord efter start, så att första
    // dubbelklicket går lika fort som resten.
    connection
        .execute_batch("PRAGMA query_only = ON; PRAGMA mmap_size = 134217728; PRAGMA cache_size = -16000;")
        .map_err(|error| error.to_string())?;
    Ok(Mutex::new(connection))
}

/// Fönstret startar dolt (se tauri.conf.json) och visas när sidan har laddats och temat är satt, så att
/// det inte blinkar vitt i mörkt tema. Visas bara en gång.
static WINDOW_SHOWN: AtomicBool = AtomicBool::new(false);

fn show_main_window_once(show: impl FnOnce()) {
    if !WINDOW_SHOWN.swap(true, Ordering::SeqCst) {
        show();
    }
}

// Öppna med (W8): filer som Windows ger appen när man väljer Öppna med i Utforskaren eller dubbelklickar
// på en bok. Gränssnittet hämtar dem med pending_take och läser dem med pending_read. Det kan bara läsa
// filer som kommit den här vägen, aldrig en valfri sökväg.

#[derive(Default)]
struct OpenFiles {
    /// Filer som har kommit men inte hämtats av gränssnittet än.
    waiting: Mutex<Vec<PathBuf>>,
    /// Filerna som gränssnittet senast hämtade, i samma ordning som listan det fick.
    taken: Mutex<Vec<PathBuf>>,
}

const OPENABLE: [&str; 8] = ["pdf", "epub", "txt", "md", "markdown", "rtf", "html", "htm"];

/// Böckerna bland argumenten (det första är programmet självt). Relativa sökvägar räknas från cwd.
fn book_arguments(arguments: &[String], cwd: Option<&Path>) -> Vec<PathBuf> {
    arguments
        .iter()
        .skip(1)
        .filter(|argument| !argument.starts_with('-'))
        .map(|argument| {
            let path = PathBuf::from(argument);
            match cwd {
                Some(directory) if path.is_relative() => directory.join(path),
                _ => path,
            }
        })
        .filter(|path| {
            path.is_file()
                && path
                    .extension()
                    .and_then(|ext| ext.to_str())
                    .is_some_and(|ext| OPENABLE.contains(&ext.to_lowercase().as_str()))
        })
        .collect()
}

fn queue_files(app: &AppHandle, files: Vec<PathBuf>) {
    if files.is_empty() {
        return;
    }
    let state = app.state::<OpenFiles>();
    state.waiting.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).extend(files);
    let _ = app.emit("lasa-open-files", ());
}

/// Filerna som väntar: namn och storlek. Listans plats används av pending_read.
#[tauri::command(async)]
fn pending_take(files: State<'_, OpenFiles>) -> Result<Vec<Value>, String> {
    let waiting: Vec<PathBuf> = std::mem::take(&mut *files.waiting.lock().unwrap_or_else(|p| p.into_inner()));
    let list = waiting
        .iter()
        .map(|path| {
            let name = path.file_name().map(|name| name.to_string_lossy().into_owned()).unwrap_or_default();
            serde_json::json!({ "name": name })
        })
        .collect();
    *files.taken.lock().unwrap_or_else(|p| p.into_inner()) = waiting;
    Ok(list)
}

/// En av filerna som pending_take gav, som råa byte.
#[tauri::command(async)]
fn pending_read(files: State<'_, OpenFiles>, index: usize) -> Result<Response, String> {
    let path = files
        .taken
        .lock()
        .unwrap_or_else(|p| p.into_inner())
        .get(index)
        .cloned()
        .ok_or_else(|| "Filen finns inte i listan.".to_string())?;
    let bytes = fs::read(&path).map_err(|error| format!("{}: {error}", path.display()))?;
    Ok(Response::new(bytes))
}

fn main() {
    tauri::Builder::default()
        // En enda instans: startas appen en gång till (till exempel med Öppna med) kommer det öppna
        // fönstret fram, och filerna öppnas där.
        .plugin(tauri_plugin_single_instance::init(|app, arguments, cwd| {
            if let Some(window) = app.get_webview_window("main") {
                let _ = window.unminimize();
                let _ = window.show();
                let _ = window.set_focus();
            }
            queue_files(app, book_arguments(&arguments, Some(Path::new(&cwd))));
        }))
        .plugin(tauri_plugin_opener::init())
        .manage(OpenFiles::default())
        .setup(|app| {
            let arguments: Vec<String> = std::env::args().collect();
            let cwd = std::env::current_dir().ok();
            let files = book_arguments(&arguments, cwd.as_deref());
            app.state::<OpenFiles>()
                .waiting
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner())
                .extend(files);
            let data = app.path().app_data_dir()?;
            let books = data.join("Böcker");
            fs::create_dir_all(&books)?;
            remove_leftovers(&books);
            let words = Connection::open(data.join("anvandarord.sqlite"))?;
            let library = Connection::open(data.join("bibliotek.sqlite"))?;
            let dictionary = open_dictionary(app);
            let all: Value = serde_json::from_str(STATEMENTS).unwrap_or(Value::Null);
            let mut store_error = None;
            for (name, connection) in [("ord", &words), ("bibliotek", &library)] {
                match all.get("databases").and_then(|databases| databases.get(name)) {
                    Some(database) => {
                        if let Err(error) = migrate(connection, database) {
                            store_error = Some(format!("Databasen {name} kunde inte göras i ordning: {error}"));
                        } else if let Err(error) = run_moves(connection, database, &data) {
                            // Transaktionen är tillbakarullad, och appen fungerar med de gamla id:na.
                            eprintln!("Flytten i databasen {name} kunde inte göras: {error}");
                        }
                    }
                    None => store_error = Some("statements.json saknar databaserna.".to_string()),
                }
            }
            let statements = Statements {
                read: named_statements(&all, "read"),
                write: named_statements(&all, "write"),
            };
            app.manage(AppState {
                dictionary,
                words: Mutex::new(words),
                library: Mutex::new(library),
                books,
                statements,
                store_error,
            });
            // Om sidan av någon anledning inte säger att den laddats visas fönstret ändå efter fyra sekunder.
            if let Some(window) = app.get_webview_window("main") {
                std::thread::spawn(move || {
                    std::thread::sleep(std::time::Duration::from_secs(4));
                    show_main_window_once(|| {
                        let _ = window.maximize();
                        let _ = window.show();
                        let _ = window.set_focus();
                    });
                });
            }
            Ok(())
        })
        .on_page_load(|webview, payload| {
            if matches!(payload.event(), PageLoadEvent::Finished) {
                let window = webview.window();
                show_main_window_once(|| {
                    let _ = window.maximize();
                    let _ = window.show();
                    let _ = window.set_focus();
                });
            }
        })
        .invoke_handler(tauri::generate_handler![
            dict_query,
            db_read,
            db_write,
            library_store,
            library_read,
            library_size,
            library_read_range,
            library_delete,
            secret_get,
            secret_set,
            pending_take,
            pending_read
        ])
        .run(tauri::generate_context!())
        .expect("Sensus kunde inte starta");
}
