# 🎥 Camera-To-ComfyUI

Real-time camera feed → ComfyUI generative pipeline

A live generative art experiment built with [Processing](https://processing.org/) and [ComfyUI](https://github.com/comfyanonymous/ComfyUI).
Captures a webcam feed, sends frames to ComfyUI via its REST API, and displays generated images side by side with the live input.

---

## 🧠 Concept

This sketch bridges **Processing** and **ComfyUI** for real-time creative AI feedback loops.
Each frame captured from the camera is:

1. Sent to ComfyUI’s API (`http://127.0.0.1:8000`),
2. Processed through a custom workflow,
3. Downloaded and displayed beside the live camera view,
4. Then automatically sends the next frame for continuous generation.

---

## ⚙️ Included Files

```
CameraAI/
├── CameraAI.pde               ← Main Processing sketch
├── ComfyUI_Workflow/          ← Portable ComfyUI workflow JSON
│     └── CameraToComfy.json
├── README.md                  ← This file
├── .gitignore
├── .gitattributes
└── windows-amd64/             ← Exported Processing app build
```

---

## 🎨 Features

* Real-time camera capture using Processing Video library
* Live API connection to ComfyUI on `localhost:8000`
* Continuous or single-frame generation modes
* Side-by-side comparison of live and generated frames
* Keyboard shortcuts for manual control and health checks
* Cross-platform support (Processing source + compiled app)

---

## ⌨️ Keyboard Shortcuts

| Key   | Action                                                                |
| ----- | --------------------------------------------------------------------- |
| **C** | Cycle through available cameras                                       |
| **R** | Refresh camera list                                                   |
| **S** | Save current frame as PNG                                             |
| **G** | Single run → save → upload → run workflow → wait → download → display |
| **L** | Start continuous loop (auto-generate after each completion)           |
| **B** | Break continuous loop (stop after current job)                        |
| **H** | Quick ComfyUI health check                                            |

---

## ▶️ How to Run

### 🧬 Option 1: Run in Processing

1. Install [Processing](https://processing.org/download/).
2. Open `CameraAI.pde`.
3. Ensure ComfyUI is running locally with API access enabled (`http://127.0.0.1:8000`).
4. Load the provided workflow JSON into ComfyUI:
   **File → Load → `CameraToComfy.json`**
5. Press **Run** in Processing.

---

### 💻 Option 2: Run the Exported App

1. Open the folder `windows-amd64/`.
2. Launch the executable (Processing runtime included).
3. Make sure ComfyUI is running with API access on `127.0.0.1:8000`.
4. The app will display the camera and AI-generated outputs side by side.

---

## 🧩 ComfyUI Workflow

The workflow file used by this sketch is included:
📄 [ComfyUI_Workflow/CameraToComfy.json](ComfyUI_Workflow/CameraToComfy.json)

To use it:

1. Open ComfyUI in your browser.
2. Go to **File → Load → CameraToComfy.json**.
3. Verify all custom nodes and checkpoints are installed.
4. Start the ComfyUI server with `--listen` or ensure API mode is active.

> 💡 This JSON is a portable version exported from ComfyUI (`File → Export`), containing no local file paths.

---

## 🧠 Dependencies

* Processing 4.x
* Processing Video Library (`Sketch → Import Library → Add Library → Video`)
* Local ComfyUI instance (`main` branch or `API` mode enabled)

---

---
