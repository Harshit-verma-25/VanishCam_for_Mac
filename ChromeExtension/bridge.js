// Runs in the extension's isolated world, so Meet's page CSP doesn't block the localhost socket.
// Receives JPEG frames from VanishCam Local and hands decoded bitmaps to page.js over a private port.
(() => {
  const SERVER = "ws://127.0.0.1:47831";

  window.addEventListener("message", (event) => {
    if (event.source !== window || event.data !== "vanish-camera-connect" || !event.ports[0]) return;
    const port = event.ports[0];
    let socket = null;
    let wanted = true;
    let decoding = false;

    const connect = () => {
      if (!wanted) return;
      socket = new WebSocket(SERVER);
      socket.onmessage = async ({ data }) => {
        if (decoding) return; // drop frames rather than fall behind
        decoding = true;
        try {
          const bitmap = await createImageBitmap(data);
          port.postMessage({ bitmap }, [bitmap]);
        } catch (_) {
          // A bad frame is skipped; the next one replaces it.
        } finally {
          decoding = false;
        }
      };
      socket.onclose = () => {
        if (wanted) setTimeout(connect, 1000);
      };
    };

    port.onmessage = ({ data }) => {
      if (data === "stop") {
        wanted = false;
        if (socket) socket.close();
        port.close();
      }
    };
    connect();
  });
})();
