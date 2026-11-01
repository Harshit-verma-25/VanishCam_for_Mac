// Runs in Meet's page world. Lists "Vanish Camera" as a camera and supplies its video track.
(() => {
  const media = navigator.mediaDevices;
  if (!media || typeof MediaStreamTrackGenerator === "undefined") return;

  const DEVICE_ID = "vanish-camera";
  const LABEL = "Vanish Camera";
  const GROUP_ID = "vanish-camera-group";
  const WIDTH = 1280;
  const HEIGHT = 720;

  const realEnumerate = media.enumerateDevices.bind(media);
  const realGetUserMedia = media.getUserMedia.bind(media);

  const fakeDevice = {
    deviceId: DEVICE_ID,
    groupId: GROUP_ID,
    kind: "videoinput",
    label: LABEL,
    getCapabilities: () => ({
      deviceId: DEVICE_ID,
      groupId: GROUP_ID,
      width: { min: 1, max: WIDTH },
      height: { min: 1, max: HEIGHT },
      frameRate: { min: 1, max: 30 },
    }),
    toJSON() {
      return { deviceId: DEVICE_ID, groupId: GROUP_ID, kind: "videoinput", label: LABEL };
    },
  };

  media.enumerateDevices = async () => [...(await realEnumerate()), fakeDevice];

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
    const generator = new MediaStreamTrackGenerator({ kind: "video" });
    const writer = generator.writable.getWriter();
    const channel = new MessageChannel();
    let lastFrameAt = 0;

    const write = (image) => {
      if (writer.desiredSize !== null && writer.desiredSize <= 0) return;
      const frame = new VideoFrame(image, { timestamp: Math.round(performance.now() * 1000) });
      writer.write(frame).catch(() => frame.close());
    };

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
      writer.close().catch(() => {});
      generator.stop();
      source = null;
    };
    return { generator, tracks: new Set(), stop };
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

  media.getUserMedia = async (constraints) => {
    if (!wantsVanish(constraints)) return realGetUserMedia(constraints);
    const stream = constraints.audio
      ? await realGetUserMedia({ audio: constraints.audio })
      : new MediaStream();
    source = source || startSource();
    stream.addTrack(decorate(source.generator.clone(), source));
    return stream;
  };
})();
