# 5_Vision_Extraction

Dedicated ShareX -> local vision ingest workspace.

## Folder Layout

- `incoming/`: copied source screenshots ingested by the API hook.
- `out/`: OCR text (`.txt`) + JSON records (`.json`) emitted by `/vision/ingest`.
- `processed/`: optional downstream parsed/normalized artifacts.
- `failed/`: optional failed ingest/debug payloads.

## ShareX Integration (Recommended)

Use a dedicated ShareX task profile for poker captures and run:

```powershell
powershell.exe -ExecutionPolicy Bypass -File A:\PokeHerFace\Version1\5_Vision_Extraction\sharex_ingest.ps1 -ImagePath "$input"
```

`$input` is the ShareX placeholder for captured file path.

## API Endpoint

The local bridge endpoint is:

`POST http://127.0.0.1:8000/vision/ingest`

JSON body:

```json
{
  "image_path": "A:\\path\\to\\capture.png",
  "source": "sharex",
  "profile": "general",
  "save_copy": true
}
```

Profiles:

- `general` (default)
- `cards`
- `numeric`
