// Hero light: relights the homepage fabric texture as the reader scrolls,
// like sun moving across cloth over a day. The cloth never moves; only the
// light does. The texture's own luminance is the height map, so the weave's
// ridges catch the light and throw soft shade. It renders on demand (one
// frame per scroll change, nothing while still) and backs out to the static
// CSS texture on reduced motion, automation, no WebGL2, or a lost context.

const VERT = `#version 300 es
in vec2 p;
void main() { gl_Position = vec4(p, 0.0, 1.0); }`;

const FRAG = `#version 300 es
precision mediump float;
uniform sampler2D t;
uniform vec2 res, img;
uniform vec2 sun;
uniform vec3 col, bg;
uniform float amt, gain, boost;
out vec4 o;
float lum(vec2 uv) { return dot(texture(t, uv).rgb, vec3(0.2126, 0.7152, 0.0722)); }
void main() {
  vec2 px = vec2(gl_FragCoord.x, res.y - gl_FragCoord.y);
  float s = max(res.x / img.x, res.y / img.y);
  vec2 dsz = img * s;
  vec2 uv = vec2(px.x - res.x + dsz.x, px.y) / dsz;
  vec2 e = 1.5 / img;
  float k = 5.0;
  vec3 n = normalize(vec3((lum(uv - vec2(e.x, 0.0)) - lum(uv + vec2(e.x, 0.0))) * k,
                          (lum(uv - vec2(0.0, e.y)) - lum(uv + vec2(0.0, e.y))) * k, 1.0));
  vec2 q = px / res;
  vec2 d = (sun - q) * vec2(res.x / res.y, 1.0);
  vec3 l = normalize(vec3(d, 0.6));
  float diff = max(dot(n, l), 0.0);
  float pool = exp(-dot(d, d) / 0.18);
  float shade = 1.0 - 0.4 * smoothstep(0.25, 1.1, length(d));
  vec3 lit = 1.0 + gain * (vec3(shade - 1.0) + col * pool * (0.3 + 0.5 * diff + 0.4 * diff * diff));
  vec3 c = texture(t, uv).rgb * mix(vec3(1.0), max(lit, 0.0), amt);
  // The canvas is boost times more opaque than the static texture; fading
  // toward the page ground by the same factor keeps the unlit cloth
  // identical to the static look, and lets the lit cloth show more.
  o = vec4(mix(bg, c, (1.0 + (boost - 1.0) * pool) / boost), 1.0);
}`;

const WARM: [number, number, number] = [1.0, 0.82, 0.55];
const COOL: [number, number, number] = [0.65, 0.78, 1.0];

function textureUrl(): string {
  const v = getComputedStyle(document.documentElement).getPropertyValue("--hero-texture");
  return /url\(["']?([^"')]+)/.exec(v)?.[1] ?? "";
}

export function mount(shell: HTMLElement): () => void {
  const canvas = document.createElement("canvas");
  canvas.className = "fabric-light";
  canvas.setAttribute("aria-hidden", "true");
  canvas.setAttribute("role", "presentation");
  const gl = canvas.getContext("webgl2", { alpha: false, antialias: false });
  if (!gl) return () => {};

  const prog = gl.createProgram()!;
  for (const [type, src] of [[gl.VERTEX_SHADER, VERT], [gl.FRAGMENT_SHADER, FRAG]] as const) {
    const sh = gl.createShader(type)!;
    gl.shaderSource(sh, src);
    gl.compileShader(sh);
    gl.attachShader(prog, sh);
  }
  gl.linkProgram(prog);
  // A shader the driver rejects would draw nothing yet still hide the
  // static texture, so a failed link backs out before the canvas is shown.
  if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) return () => {};
  shell.prepend(canvas);
  gl.useProgram(prog);
  gl.bindBuffer(gl.ARRAY_BUFFER, gl.createBuffer());
  gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
  gl.enableVertexAttribArray(0);
  gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 0, 0);
  const u = (n: string) => gl.getUniformLocation(prog, n);
  gl.bindTexture(gl.TEXTURE_2D, gl.createTexture());
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);

  let ready = false;
  let visible = true;
  let frame = 0;
  let url = "";

  const draw = () => {
    frame = 0;
    if (!ready || gl.isContextLost()) return;
    const dpr = Math.min(devicePixelRatio, 2);
    const w = Math.round(canvas.clientWidth * dpr);
    const h = Math.round(canvas.clientHeight * dpr);
    if (!w || !h) return;
    if (canvas.width !== w || canvas.height !== h) {
      canvas.width = w;
      canvas.height = h;
      gl.viewport(0, 0, w, h);
    }
    const p = Math.min(Math.max(scrollY / (innerHeight / 2), 0), 1);
    const dark = url.includes("dark");
    gl.uniform2f(u("res"), w, h);
    gl.uniform2f(u("sun"), 0.1 + 0.9 * p, 0.65 - 0.5 * Math.sin(Math.PI * p));
    gl.uniform3fv(u("col"), dark ? COOL : WARM);
    gl.uniform1f(u("amt"), dark ? 0.8 : 1);
    // The dark cloth needs more contrast, and more of it shown where lit,
    // for the moonlight to read at all; the light theme's sun needs neither.
    const boost = dark ? 1.6 : 1;
    gl.uniform1f(u("gain"), dark ? 2.5 : 1);
    gl.uniform1f(u("boost"), boost);
    const ground = getComputedStyle(document.body).backgroundColor.match(/[\d.]+/g)?.map(Number) ?? [0, 0, 0];
    gl.uniform3f(u("bg"), ground[0] / 255, ground[1] / 255, ground[2] / 255);
    canvas.style.setProperty("--fabric-light-boost", String(boost));
    gl.drawArrays(gl.TRIANGLES, 0, 3);
    canvas.setAttribute("data-live", "");
  };
  const request = () => {
    if (visible && !document.hidden && !frame) frame = requestAnimationFrame(draw);
  };

  const load = () => {
    const next = textureUrl();
    if (!next || next === url) return;
    url = next;
    const im = new Image();
    im.onload = () => {
      if (url !== next) return;
      gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, im);
      gl.uniform2f(u("img"), im.naturalWidth, im.naturalHeight);
      ready = true;
      request();
    };
    im.src = next;
  };

  const themeWatch = new MutationObserver(load);
  themeWatch.observe(document.documentElement, { attributes: true, attributeFilter: ["data-theme"] });
  const scheme = matchMedia("(prefers-color-scheme: dark)");
  scheme.addEventListener("change", load);
  const seen = new IntersectionObserver(([entry]) => {
    visible = entry.isIntersecting;
    request();
  });
  seen.observe(canvas);
  const sized = new ResizeObserver(request);
  sized.observe(canvas);
  const lost = (e: Event) => {
    e.preventDefault();
    unmount();
  };
  canvas.addEventListener("webglcontextlost", lost);
  addEventListener("scroll", request, { passive: true });
  document.addEventListener("visibilitychange", request);
  load();

  function unmount() {
    cancelAnimationFrame(frame);
    themeWatch.disconnect();
    scheme.removeEventListener("change", load);
    seen.disconnect();
    sized.disconnect();
    removeEventListener("scroll", request);
    document.removeEventListener("visibilitychange", request);
    canvas.removeEventListener("webglcontextlost", lost);
    canvas.remove();
  }
  return unmount;
}
