; Öppna med i Utforskaren (W8). Appen läggs till i listan Öppna med för PDF och EPUB, men blir inte
; standardprogram för filerna: det valet gör man själv i Windows. Allt skrivs under HKCU, eftersom appen
; installeras för den egna användaren, och tas bort när appen avinstalleras.

!macro NSIS_HOOK_POSTINSTALL
  WriteRegStr HKCU "Software\Classes\Sensus.Bok" "" "Bok i Sensus"
  WriteRegStr HKCU "Software\Classes\Sensus.Bok\DefaultIcon" "" "$INSTDIR\${MAINBINARYNAME}.exe,0"
  WriteRegStr HKCU "Software\Classes\Sensus.Bok\shell\open\command" "" '"$INSTDIR\${MAINBINARYNAME}.exe" "%1"'
  WriteRegStr HKCU "Software\Classes\.pdf\OpenWithProgids" "Sensus.Bok" ""
  WriteRegStr HKCU "Software\Classes\.epub\OpenWithProgids" "Sensus.Bok" ""
  WriteRegStr HKCU "Software\Classes\Applications\${MAINBINARYNAME}.exe" "FriendlyAppName" "Sensus"
  WriteRegStr HKCU "Software\Classes\Applications\${MAINBINARYNAME}.exe\SupportedTypes" ".pdf" ""
  WriteRegStr HKCU "Software\Classes\Applications\${MAINBINARYNAME}.exe\SupportedTypes" ".epub" ""
  WriteRegStr HKCU "Software\Classes\Applications\${MAINBINARYNAME}.exe\shell\open\command" "" '"$INSTDIR\${MAINBINARYNAME}.exe" "%1"'
  ; Utforskaren läser om filtyperna.
  System::Call 'shell32::SHChangeNotify(i 0x08000000, i 0, p 0, p 0)'
!macroend

!macro NSIS_HOOK_POSTUNINSTALL
  DeleteRegValue HKCU "Software\Classes\.pdf\OpenWithProgids" "Sensus.Bok"
  DeleteRegValue HKCU "Software\Classes\.epub\OpenWithProgids" "Sensus.Bok"
  DeleteRegKey HKCU "Software\Classes\Sensus.Bok"
  DeleteRegKey HKCU "Software\Classes\Applications\${MAINBINARYNAME}.exe"
  System::Call 'shell32::SHChangeNotify(i 0x08000000, i 0, p 0, p 0)'
!macroend
