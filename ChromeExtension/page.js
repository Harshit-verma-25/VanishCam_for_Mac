// Runs in Meet's page world. Lists "Vanish Camera" as a camera and supplies its video track.
(() => {
  if (typeof MediaDevices === "undefined" || !navigator.mediaDevices) return;
  const proto = MediaDevices.prototype;

  // Shaped like Chrome's own ids (64 hex chars), in case Meet drops ids that don't look real.
  const DEVICE_ID = "7661" + "6e697368".repeat(7) + "6361";
  const LABEL = "Vanish Camera";
  const GROUP_ID = "7661" + "6e697368".repeat(7) + "6772";
  const WIDTH = 1280;
  const HEIGHT = 720;

  const realEnumerateFn = proto.enumerateDevices;
  const realGetUserMediaFn = proto.getUserMedia;
  const media = navigator.mediaDevices;
  const realEnumerate = () => realEnumerateFn.call(media);
  const realGetUserMedia = (constraints) => realGetUserMediaFn.call(media, constraints);

  // Meet filters devices with instanceof, so this inherits from InputDeviceInfo and shadows its getters.
  const DeviceProto = typeof InputDeviceInfo !== "undefined" ? InputDeviceInfo.prototype : Object.prototype;
  const fakeDevice = Object.create(DeviceProto, {
    deviceId: { value: DEVICE_ID, enumerable: true },
    groupId: { value: GROUP_ID, enumerable: true },
    kind: { value: "videoinput", enumerable: true },
    label: { value: LABEL, enumerable: true },
    getCapabilities: {
      value: () => ({
        deviceId: DEVICE_ID,
        groupId: GROUP_ID,
        width: { min: 1, max: WIDTH },
        height: { min: 1, max: HEIGHT },
        frameRate: { min: 1, max: 30 },
      }),
    },
    toJSON: {
      value: () => ({ deviceId: DEVICE_ID, groupId: GROUP_ID, kind: "videoinput", label: LABEL }),
    },
  });

  // Patched on the prototype, so callers that reach for MediaDevices.prototype directly see it too.
  proto.enumerateDevices = async function () {
    const devices = await realEnumerate();
    return devices.some((d) => d.deviceId === DEVICE_ID) ? devices : [...devices, fakeDevice];
  };

  // MediaStreamTrackGenerator is window-only in older Chrome and worker-only in newer builds,
  // so fall back to a captured canvas, which every Chrome supports.
  const makeOutput = () => {
    if (typeof MediaStreamTrackGenerator !== "undefined") {
      const generator = new MediaStreamTrackGenerator({ kind: "video" });
      const writer = generator.writable.getWriter();
      return {
        track: generator,
        draw: (image) => {
          if (writer.desiredSize !== null && writer.desiredSize <= 0) return;
          const frame = new VideoFrame(image, { timestamp: Math.round(performance.now() * 1000) });
          writer.write(frame).catch(() => frame.close());
        },
        close: () => {
          writer.close().catch(() => {});
          generator.stop();
        },
      };
    }
    const canvas = document.createElement("canvas");
    canvas.width = WIDTH;
    canvas.height = HEIGHT;
    const context = canvas.getContext("2d");
    const track = canvas.captureStream(30).getVideoTracks()[0];
    return {
      track,
      draw: (image) => context.drawImage(image, 0, 0, WIDTH, HEIGHT),
      close: () => track.stop(),
    };
  };

  const idsIn = (value) => {
    if (value == null) return [];
    if (typeof value === "object" && !Array.isArray(value)) {
      return [].concat(value.exact ?? [], value.ideal ?? []);
    }
    return [].concat(value);
  };

  const wantsVanish = (constraints) => {
    const video = constraints && constraints.video;
    if (!video || typeof video !== "object") return false;
    return [video, ...(video.advanced || [])].some((set) => idsIn(set.deviceId).includes(DEVICE_ID));
  };

  // One live source, shared by every track Meet holds. It stops when the last track stops.
  let source = null;

  const startSource = () => {
    const output = makeOutput();
    const channel = new MessageChannel();
    let lastFrameAt = 0;
    const write = output.draw;

    channel.port1.onmessage = ({ data }) => {
      lastFrameAt = performance.now();
      write(data.bitmap);
      data.bitmap.close();
    };
    window.postMessage("vanish-camera-connect", location.origin, [channel.port2]);

    // Shown until frames arrive, or if the app is closed mid-call.
    const canvas = new OffscreenCanvas(WIDTH, HEIGHT);
    const context = canvas.getContext("2d");
    context.fillStyle = "#12141c";
    context.fillRect(0, 0, WIDTH, HEIGHT);
    context.fillStyle = "#fff";
    context.font = "40px sans-serif";
    context.textAlign = "center";
    context.fillText("Open the VanishCam Local app", WIDTH / 2, HEIGHT / 2);
    const placeholder = setInterval(() => {
      if (performance.now() - lastFrameAt > 1000) write(canvas);
    }, 200);

    const stop = () => {
      clearInterval(placeholder);
      channel.port1.postMessage("stop");
      channel.port1.close();
      output.close();
      source = null;
    };
    return { generator: output.track, tracks: new Set(), stop };
  };

  // Makes a generator track look like a camera to Meet, which checks the settings for its device id.
  const decorate = (track, owner) => {
    owner.tracks.add(track);
    const realStop = track.stop.bind(track);
    const realClone = track.clone.bind(track);
    const realSettings = track.getSettings.bind(track);

    Object.defineProperty(track, "label", { get: () => LABEL });
    track.getSettings = () => ({
      ...realSettings(),
      deviceId: DEVICE_ID,
      groupId: GROUP_ID,
      width: WIDTH,
      height: HEIGHT,
      frameRate: 30,
    });
    track.getCapabilities = fakeDevice.getCapabilities;
    track.applyConstraints = async () => {};
    track.clone = () => decorate(realClone(), owner);
    track.stop = () => {
      realStop();
      owner.tracks.delete(track);
      if (owner.tracks.size === 0) owner.stop();
    };
    return track;
  };

  proto.getUserMedia = async function (constraints) {
    if (!wantsVanish(constraints)) return realGetUserMedia(constraints);
    const stream = constraints.audio
      ? await realGetUserMedia({ audio: constraints.audio })
      : new MediaStream();
    source = source || startSource();
    stream.addTrack(decorate(source.generator.clone(), source));
    return stream;
  };

  // Shows in DevTools whether the extension reached this tab.
  console.info("[Vanish Camera] active, output:",
    typeof MediaStreamTrackGenerator !== "undefined" ? "track generator" : "canvas");
})();
