# Tracker rebuild notes

The tracker was rebuilt on a small web stack. Data moved from two spreadsheets into one SQLite file.
Login was reworked to a single session cookie. The coach view and the client view now share one code
path. Exports run on demand and write a CSV. Support runs for fourteen days after handover, then a
paid quarterly package. The build took longer than planned because the scope was simplified twice.
