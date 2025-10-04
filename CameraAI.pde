/**
 * Processing ⇄ ComfyUI round-trip (looping version)
 *
 * Keys:
 *   [c] cycle camera
 *   [r] refresh camera list
 *   [s] save current frame (PNG)
 *   [g] single run: save → upload → run workflow → wait → download → display
 *   [l] start continuous loop (auto-generate after each completion)
 *   [b] break continuous loop (stops after current job)
 *   [h] quick health check
 */

import processing.video.*;
import processing.data.JSONObject;
import processing.data.JSONArray;

import java.io.*;
import java.net.*;
import java.util.*;

Capture cam;
String[] cameraList = null;
int camIndex = 0;

// <<< Set to your ComfyUI address/port >>>
String comfy = "http://127.0.0.1:8000";

String statusMsg = "Ready";
PImage lastResult;

volatile boolean working = false;      // true while a job is being processed
volatile boolean loopRunning = false;  // continuous loop flag

void setup() {
  size(960, 540);
  surface.setTitle("Processing ⇄ ComfyUI (Loop)");
  refreshCameras();
}

void draw() {
  background(20);

  // keep the camera fresh
  if (cam != null && cam.available()) {
    try { cam.read(); } catch (Exception e) { reopenFirstAvailable(); }
  }

  // panels
  float leftX = 0, leftW = width * 0.5f, leftH = height;
  float rightX = width * 0.5f, rightW = width * 0.5f, rightH = height;

  // left: live camera (preserve aspect)
  if (cam != null && cam.width > 0) {
    drawImageInPanel(cam, leftX, 0, leftW, leftH);
  } else {
    fill(50); noStroke(); rect(leftX, 0, leftW, leftH);
    fill(200); textAlign(CENTER, CENTER); text("No camera", leftX + leftW/2, leftH/2);
  }

  // right: last Comfy result (preserve aspect)
  if (lastResult != null) {
    drawImageInPanel(lastResult, rightX, 0, rightW, rightH);
  } else {
    fill(30); noStroke(); rect(rightX, 0, rightW, rightH);
  }

  // HUD
  fill(255);
  textAlign(LEFT, TOP);
  String currentCamName = (cameraList != null && cameraList.length > 0) ? cameraList[camIndex] : "none";
  text(
    "Comfy port: " + comfy + "\n" +
    "Cameras: " + Arrays.toString(cameraList) + "\n" +
    "Current: " + currentCamName + "\n" +
    "Keys: [c]=cycle  [r]=refresh  [s]=save  [g]=single  [l]=loop start  [b]=loop stop  [h]=health\n" +
    "Loop: " + (loopRunning ? "RUNNING" : "stopped") + "   Working: " + (working ? "yes" : "no") + "\n" +
    statusMsg,
    10, 10
  );
}

/** Draws img into a panel at (px,py) sized (pw,ph) without distortion (letterbox/pillarbox). */
void drawImageInPanel(PImage img, float px, float py, float pw, float ph) {
  float imgAspect = (float) img.width / (float) img.height;
  float panelAspect = pw / ph;

  float dw, dh, ox, oy;
  if (imgAspect > panelAspect) {
    // image is wider → fit to panel width
    dw = pw;
    dh = pw / imgAspect;
    ox = px;
    oy = py + (ph - dh) * 0.5f;
  } else {
    // image is taller → fit to panel height
    dh = ph;
    dw = ph * imgAspect;
    ox = px + (pw - dw) * 0.5f;
    oy = py;
  }

  // optional: paint background of the panel (letterbox bars)
  noStroke();
  fill(20);
  rect(px, py, pw, ph);

  image(img, ox, oy, dw, dh);
}

/* =========================
   Keyboard
   ========================= */

void keyPressed() {
  char k = Character.toLowerCase(key);

  if (k == 'c') cycleCamera();
  if (k == 'r') refreshCameras();

  if (k == 's') {
    String fn = saveFrameNow();
    statusMsg = "Saved: " + fn;
  }

  if (k == 'h') {
    new Thread(() -> {
      try {
        URL url = new URL(comfy + "/queue/status?client_id=processing-app");
        HttpURLConnection conn = (HttpURLConnection) url.openConnection();
        conn.setConnectTimeout(3000);
        conn.setReadTimeout(3000);
        String resp = readAll(conn);
        statusMsg = "ComfyUI OK: " + resp;
      } catch (Exception ex) {
        statusMsg = "ComfyUI unreachable at " + comfy;
      }
    }).start();
  }

  if (k == 'g' && !working) startSingleRun();

  // start loop
  if (k == 'l') startLoop();

  // break loop
  if (k == 'b') {
    loopRunning = false;
    statusMsg = "Loop stop requested (will stop after current job).";
  }
}

/* =========================
   Loop control
   ========================= */

void startSingleRun() {
  working = true;
  statusMsg = "Single run: capturing...";
  new Thread(() -> {
    try { runOneIteration(); }
    finally { working = false; }
  }).start();
}

void startLoop() {
  if (loopRunning) { statusMsg = "Loop already running."; return; }
  loopRunning = true;
  if (!working) {
    working = true;
    statusMsg = "Loop started.";
    new Thread(() -> {
      try {
        while (loopRunning) {
          runOneIteration();
          if (!loopRunning) break;
          // Optional small pacing delay between iterations
          delay(200);
        }
        statusMsg = "Loop stopped.";
      } finally {
        working = false;
      }
    }).start();
  } else {
    statusMsg = "Loop will start after current job finishes.";
  }
}

/* =========================
   One full iteration
   ========================= */

void runOneIteration() {
  try {
    // 1) Save frame
    statusMsg = "Capturing...";
    String localFile = saveFrameNow();

    // 2) Upload
    statusMsg = "Uploading to ComfyUI...";
    String comfyFilename = uploadImageToComfy(localFile);

    // 3) Build workflow (patch node 34)
    statusMsg = "Queuing prompt...";
    JSONObject promptBody = buildPatchedWorkflow(comfyFilename);

    // 4) POST /prompt
    String promptId = postPrompt(promptBody);

    // 5) Poll for result
    statusMsg = "Generating...";
    JSONObject out = waitForResult(promptId, 180000); // 180s timeout for loop stability

    if (out != null) {
      String filename  = out.getString("filename");
      String subfolder = out.hasKey("subfolder") ? out.getString("subfolder") : "";
      String type      = out.hasKey("type") ? out.getString("type") : "output";

      String url = comfy + "/view?filename=" + URLEncoder.encode(filename, "UTF-8")
                   + "&subfolder=" + URLEncoder.encode(subfolder, "UTF-8")
                   + "&type=" + URLEncoder.encode(type, "UTF-8");

      statusMsg = "Downloading result...";
      lastResult = downloadAndLoadPImage(url, filename);
      statusMsg = (lastResult != null) ? ("Done: " + filename) : "Failed to load result image.";
    } else {
      statusMsg = "Timed out waiting for result.";
    }
  } catch (java.net.ConnectException ce) {
    statusMsg = "Cannot reach ComfyUI at " + comfy + " (running? port correct?)";
    // If loop is running and server vanished, stop the loop to avoid tight retries
    loopRunning = false;
  } catch (Exception e) {
    e.printStackTrace();
    statusMsg = "Error: " + e.getMessage();
  }
}

/* =========================
   Camera helpers
   ========================= */

void refreshCameras() {
  try { cameraList = Capture.list(); } catch (Throwable t) { cameraList = null; }

  if (cameraList == null || cameraList.length == 0) {
    println("No cameras found.");
    closeCamera();
    statusMsg = "No cameras found (check privacy settings / close other apps).";
    return;
  }

  println("Available cameras:");
  for (int i = 0; i < cameraList.length; i++) println(i + ": " + cameraList[i]);

  camIndex = constrain(camIndex, 0, cameraList.length - 1);
  openCamera(camIndex);
}

void cycleCamera() {
  if (cameraList == null || cameraList.length == 0) { refreshCameras(); return; }
  camIndex = (camIndex + 1) % cameraList.length;
  openCamera(camIndex);
}

void reopenFirstAvailable() {
  if (cameraList == null || cameraList.length == 0) { refreshCameras(); return; }
  openCamera(0);
}

void openCamera(int idx) {
  closeCamera();
  try {
    cam = new Capture(this, cameraList[idx]);
    cam.start();
    statusMsg = "Opened: " + cameraList[idx];
    println("Opened camera: " + cameraList[idx]);
  } catch (Exception e) {
    println("Failed to open camera index " + idx + ": " + e);
    statusMsg = "Open failed; trying next.";
    for (int i = 0; i < cameraList.length; i++) {
      if (i == idx) continue;
      try {
        cam = new Capture(this, cameraList[i]);
        cam.start();
        camIndex = i;
        statusMsg = "Opened: " + cameraList[i];
        println("Opened fallback camera: " + cameraList[i]);
        return;
      } catch (Exception ignored) {}
    }
    statusMsg = "Could not open any camera.";
    cam = null;
  }
}

void closeCamera() {
  if (cam != null) {
    try { cam.stop(); } catch (Exception ignore) {}
    cam = null;
  }
}

/* =========================
   ComfyUI integration
   ========================= */

String saveFrameNow() {
  String ts = nf(year(),4) + nf(month(),2) + nf(day(),2) + "-" + nf(hour(),2) + nf(minute(),2) + nf(second(),2);
  String fn = "frame-" + ts + ".png";
  PImage shot = (cam != null && cam.width > 0) ? cam.get() : get(0, 0, width/2, height);
  shot.save(fn);
  return fn;
}

String uploadImageToComfy(String localPath) throws Exception {
  String boundary = "----procBoundary" + System.currentTimeMillis();
  URL url = new URL(comfy + "/upload/image");
  HttpURLConnection conn = (HttpURLConnection) url.openConnection();
  conn.setDoOutput(true);
  conn.setRequestMethod("POST");
  conn.setRequestProperty("Content-Type", "multipart/form-data; boundary=" + boundary);
  conn.setConnectTimeout(5000);
  conn.setReadTimeout(120000);

  try (DataOutputStream out = new DataOutputStream(conn.getOutputStream())) {
    File f = new File(localPath);
    out.writeBytes("--" + boundary + "\r\n");
    out.writeBytes("Content-Disposition: form-data; name=\"image\"; filename=\"" + f.getName() + "\"\r\n");
    out.writeBytes("Content-Type: image/png\r\n\r\n");
    byte[] bytes = loadBytes(localPath);
    out.write(bytes);
    out.writeBytes("\r\n--" + boundary + "--\r\n");
    out.flush();
  }

  String resp = readAll(conn);
  JSONObject j = parseJSONSafe(resp);
  if (j != null) {
    if (j.hasKey("name")) return j.getString("name");
    if (j.hasKey("files")) {
      JSONArray a = j.getJSONArray("files");
      if (a != null && a.size() > 0) return a.getString(0);
    }
  }
  return new File(localPath).getName();
}

JSONObject buildPatchedWorkflow(String comfyFilename) {
  // Your new exported workflow, with __INPUT__ placeholder for node 14 → "image"
  String workflow =
  "{"
  + "\"3\":{\"inputs\":{\"seed\":560041135393003,\"steps\":30,\"cfg\":7,"
  + "\"sampler_name\":\"dpmpp_2m\",\"scheduler\":\"karras\",\"denoise\":0.45,"
  + "\"model\":[\"4\",0],\"positive\":[\"6\",0],\"negative\":[\"7\",0],\"latent_image\":[\"15\",0]},"
  + "\"class_type\":\"KSampler\",\"_meta\":{\"title\":\"KSampler\"}},"

  + "\"4\":{\"inputs\":{\"ckpt_name\":\"dreamshaper_8.safetensors\"},"
  + "\"class_type\":\"CheckpointLoaderSimple\",\"_meta\":{\"title\":\"Load Checkpoint\"}},"

  + "\"6\":{\"inputs\":{\"text\":\"make the person a futuristic woman like robot\\n\","
  + "\"speak_and_recognation\":{\"__value__\":[false,true]},\"clip\":[\"4\",1]},"
  + "\"class_type\":\"CLIPTextEncode\",\"_meta\":{\"title\":\"CLIP Text Encode (Prompt)\"}},"

  + "\"7\":{\"inputs\":{\"text\":\"(worst quality, low quality:1.4), (bad anatomy), text, error, missing fingers, extra digit, fewer digits, cropped, jpeg artifacts, signature, watermark, username, blurry, deformed face,\","
  + "\"speak_and_recognation\":{\"__value__\":[false,true]},\"clip\":[\"4\",1]},"
  + "\"class_type\":\"CLIPTextEncode\",\"_meta\":{\"title\":\"CLIP Text Encode (Prompt)\"}},"

  + "\"8\":{\"inputs\":{\"samples\":[\"3\",0],\"vae\":[\"4\",2]},"
  + "\"class_type\":\"VAEDecode\",\"_meta\":{\"title\":\"VAE Decode\"}},"

  + "\"9\":{\"inputs\":{\"filename_prefix\":\"2loras_test_\",\"images\":[\"8\",0]},"
  + "\"class_type\":\"SaveImage\",\"_meta\":{\"title\":\"Save Image\"}},"

  + "\"14\":{\"inputs\":{\"image\":\"__INPUT__\"},"
  + "\"class_type\":\"LoadImage\",\"_meta\":{\"title\":\"Load Image\"}},"

  + "\"15\":{\"inputs\":{\"pixels\":[\"14\",0],\"vae\":[\"4\",2]},"
  + "\"class_type\":\"VAEEncode\",\"_meta\":{\"title\":\"VAE Encode\"}}"
  + "}";

  workflow = workflow.replace("__INPUT__", comfyFilename);

  JSONObject body = new JSONObject();
  body.setJSONObject("prompt", JSONObject.parse(workflow));
  body.setString("client_id", "processing-app");
  return body;
}

String postPrompt(JSONObject body) throws Exception {
  URL url = new URL(comfy + "/prompt");
  HttpURLConnection conn = (HttpURLConnection) url.openConnection();
  conn.setDoOutput(true);
  conn.setRequestMethod("POST");
  conn.setRequestProperty("Content-Type", "application/json");
  conn.setConnectTimeout(5000);
  conn.setReadTimeout(180000);
  try (OutputStream os = conn.getOutputStream()) {
    byte[] b = body.toString().getBytes("UTF-8");
    os.write(b);
  }
  String resp = readAll(conn);
  JSONObject j = parseJSONSafe(resp);
  if (j == null || !j.hasKey("prompt_id")) throw new RuntimeException("Bad /prompt response: " + resp);
  return j.getString("prompt_id");
}

JSONObject waitForResult(String promptId, int timeoutMs) throws Exception {
  long endAt = millis() + timeoutMs;
  while (millis() < endAt) {
    URL url = new URL(comfy + "/history/" + URLEncoder.encode(promptId, "UTF-8"));
    HttpURLConnection conn = (HttpURLConnection) url.openConnection();
    conn.setRequestMethod("GET");
    conn.setConnectTimeout(5000);
    conn.setReadTimeout(180000);
    String resp = readAll(conn);

    JSONObject j = parseJSONSafe(resp);
    if (j != null && j.hasKey(promptId)) {
      JSONObject rec = j.getJSONObject(promptId);
      if (rec != null && rec.hasKey("outputs")) {
        JSONObject outputs = rec.getJSONObject("outputs");
        // Target SaveImage node "9" (adjust if your graph changes)
        if (outputs != null && outputs.hasKey("9")) {
          JSONObject nine = outputs.getJSONObject("9");
          if (nine != null && nine.hasKey("images")) {
            JSONArray imgs = nine.getJSONArray("images");
            if (imgs != null && imgs.size() > 0) return imgs.getJSONObject(0);
          }
        }
      }
    }
    delay(700);
  }
  return null;
}

/* =========================
   IO helpers
   ========================= */

PImage downloadAndLoadPImage(String urlStr, String filenameHint) {
  try {
    URL url = new URL(urlStr);
    HttpURLConnection c = (HttpURLConnection) url.openConnection();
    c.setConnectTimeout(5000);
    c.setReadTimeout(180000);
    c.setRequestProperty("Accept", "image/*");
    c.setUseCaches(false);

    int code = c.getResponseCode();
    if (code != 200) {
      println("Comfy view HTTP " + code + " for " + urlStr);
      return null;
    }

    // extension from filename
    String ext = ".png";
    String lower = (filenameHint == null) ? "" : filenameHint.toLowerCase();
    if (lower.endsWith(".jpg") || lower.endsWith(".jpeg")) ext = ".jpg";
    else if (lower.endsWith(".gif")) ext = ".gif";
    else if (lower.endsWith(".bmp")) ext = ".bmp";
    else if (lower.endsWith(".tif") || lower.endsWith(".tiff")) ext = ".tif";

    String tmp = sketchPath("comfy_result" + ext);
    try (InputStream in = c.getInputStream();
         FileOutputStream fos = new FileOutputStream(tmp)) {
      byte[] buf = new byte[32 * 1024];
      int n;
      while ((n = in.read(buf)) > 0) fos.write(buf, 0, n);
    }
    PImage img = loadImage(tmp);
    if (img == null) println("loadImage failed for temp file: " + tmp);
    return img;
  } catch (Exception ex) {
    ex.printStackTrace();
    return null;
  }
}

static String readAll(URLConnection conn) throws Exception {
  InputStream is = null;
  try { is = conn.getInputStream(); }
  catch (IOException e) { if (conn instanceof HttpURLConnection) is = ((HttpURLConnection)conn).getErrorStream(); }
  if (is == null) return "";
  BufferedReader br = new BufferedReader(new InputStreamReader(is, "UTF-8"));
  StringBuilder sb = new StringBuilder();
  for (String line; (line = br.readLine()) != null; ) sb.append(line);
  br.close();
  return sb.toString();
}

static JSONObject parseJSONSafe(String s) {
  try { return JSONObject.parse(s); }
  catch (Exception e) { return null; }
}
