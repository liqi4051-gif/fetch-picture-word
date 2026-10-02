/* fetch-picture-word - dialog front end.
 *
 * Everything runs on this machine: the page posts a PNG to the local server in
 * scripts/preview.py, which hands it to scripts/ocr.ps1 and the Windows OCR
 * engine. No image ever leaves the computer.
 */
'use strict';

const chat = document.getElementById('chat');
const fileInput = document.getElementById('file');
const alertBox = document.getElementById('alert');
const toastBox = document.getElementById('toast');
const dot = document.getElementById('dot');
const engineLabel = document.getElementById('engine');
const btnRegion = document.getElementById('btn-region');
const btnPaste = document.getElementById('btn-paste');

let pending = 0;

/* ------------------------------------------------------------------ helpers */

function toast(message) {
    toastBox.textContent = message;
    toastBox.classList.add('show');
    clearTimeout(toastBox._timer);
    toastBox._timer = setTimeout(() => toastBox.classList.remove('show'), 2400);
}

function showAlert(message) {
    alertBox.textContent = message;
    alertBox.classList.add('show');
}

function timeLabel() {
    const d = new Date();
    const p = (n) => String(n).padStart(2, '0');
    return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}`;
}

function scrollToEnd() {
    chat.scrollTop = chat.scrollHeight;
}

/** One chat row. kind is 'me' or 'bot'; payload is an <img> or a string. */
function addRow(kind, payload, meta) {
    const row = document.createElement('div');
    row.className = `row ${kind}`;

    const avatar = document.createElement('div');
    avatar.className = 'avatar';
    avatar.textContent = kind === 'me' ? '我' : '图';
    row.appendChild(avatar);

    const body = document.createElement('div');
    body.className = 'body';
    const bubble = document.createElement('div');
    bubble.className = 'bubble';
    if (payload instanceof Node) {
        bubble.appendChild(payload);
    } else {
        bubble.classList.add('text');
        if (!payload) { bubble.classList.add('is-empty'); }
        bubble.textContent = payload || '';
    }
    body.appendChild(bubble);

    if (meta) {
        const line = document.createElement('div');
        line.className = 'meta';
        line.textContent = meta;
        body.appendChild(line);
    }
    row.appendChild(body);
    chat.appendChild(row);
    scrollToEnd();
    return { row, body, bubble };
}

function addBusyRow() {
    const spinner = document.createElement('span');
    spinner.className = 'spinner';
    spinner.innerHTML = '<i></i><i></i><i></i>';
    const { body } = addRow('bot', spinner, timeLabel());
    pending += 1;
    btnRegion.disabled = true;
    return body;
}

function finishBusy() {
    pending = Math.max(0, pending - 1);
    btnRegion.disabled = pending > 0;
}

/* --------------------------------------------------------------- OCR result */

function renderResult(source, result, elapsedMs) {
    const { body } = addRow('bot', result.text);
    const stats = result.stats || {};

    const meta = document.createElement('div');
    meta.className = 'meta';
    meta.textContent = `${source} · 共 ${stats.wordCount || 0} 词 · ${stats.lineCount || 0} 行 · ${Math.round(elapsedMs)} ms`;
    body.appendChild(meta);

    const actions = document.createElement('div');
    actions.className = 'actions';

    const copy = document.createElement('button');
    copy.type = 'button';
    copy.textContent = '复制文字';
    copy.addEventListener('click', async () => {
        try {
            await navigator.clipboard.writeText(result.text);
            toast('已复制到剪贴板');
        } catch (err) {
            toast('复制失败，请手动选择文字');
        }
    });
    actions.appendChild(copy);

    if (result.raw && result.raw !== result.text) {
        const raw = document.createElement('pre');
        raw.className = 'raw';
        raw.textContent = result.raw;
        const toggle = document.createElement('button');
        toggle.type = 'button';
        toggle.textContent = '查看原始识别结果';
        toggle.addEventListener('click', () => {
            const shown = raw.classList.toggle('show');
            toggle.textContent = shown ? '收起原始识别结果' : '查看原始识别结果';
            scrollToEnd();
        });
        actions.appendChild(toggle);
        body.appendChild(actions);
        body.appendChild(raw);
    } else {
        body.appendChild(actions);
    }
    scrollToEnd();
}

/* ------------------------------------------------------------------ pipeline */

async function toPngBlob(source) {
    if (source instanceof Blob) {
        return source;
    }
    const bitmap = await createImageBitmap(source);
    const canvas = document.createElement('canvas');
    canvas.width = bitmap.width;
    canvas.height = bitmap.height;
    canvas.getContext('2d').drawImage(bitmap, 0, 0);
    bitmap.close();
    return new Promise((resolve) => canvas.toBlob(resolve, 'image/png'));
}

async function recognize(source, label) {
    const blob = await toPngBlob(source);
    const url = URL.createObjectURL(blob);
    const preview = document.createElement('img');
    preview.src = url;
    preview.alt = label;
    preview.addEventListener('load', () => URL.revokeObjectURL(url), { once: true });
    addRow('me', preview, `${label} · ${timeLabel()}`);

    const busy = addBusyRow();
    const started = performance.now();
    try {
        const response = await fetch('api/ocr', {
            method: 'POST',
            headers: { 'Content-Type': 'image/png' },
            body: blob
        });
        const result = await response.json();
        busy.closest('.row').remove();
        if (result.ok) {
            renderResult(label, result, performance.now() - started);
        } else {
            addRow('bot', `识别失败：${result.error || '未知错误'}`, label);
            setEngineState('bad', '识别引擎出错');
        }
    } catch (err) {
        busy.closest('.row').remove();
        addRow('bot', `无法连接本机识别服务：${err.message}\n请在 skill 目录重新运行 scripts/preview.py 后刷新页面。`, label);
        setEngineState('bad', '未连接');
    } finally {
        finishBusy();
    }
}

function setEngineState(kind, text) {
    dot.className = `dot ${kind}`;
    engineLabel.textContent = text;
}

/* ------------------------------------------------------------ region capture */

let screenStream = null;

function clipOf(stream) {
    const track = stream.getVideoTracks()[0];
    const settings = track.getSettings ? track.getSettings() : {};
    return Array.isArray(settings.clip) ? settings.clip : null;
}

async function captureRegion() {
    if (!navigator.mediaDevices || !navigator.mediaDevices.getDisplayMedia) {
        showAlert('此浏览器不支持屏幕捕获，请用系统截图工具截图后在本页面按 Ctrl+V 粘贴。');
        return;
    }
    let stream;
    try {
        stream = await navigator.mediaDevices.getDisplayMedia({ video: true, audio: false });
    } catch (err) {
        if (err && err.name === 'NotAllowedError') { toast('已取消区域截图'); return; }
        showAlert(`无法启动区域截图：${err.message}`);
        return;
    }

    const video = document.createElement('video');
    video.srcObject = stream;
    video.muted = true;
    await video.play().catch(() => { });
    await new Promise((resolve) => setTimeout(resolve, 220));

    const frame = document.createElement('canvas');
    frame.width = video.videoWidth;
    frame.height = video.videoHeight;
    frame.getContext('2d').drawImage(video, 0, 0);

    const clip = clipOf(stream);
    stream.getTracks().forEach((track) => track.stop());

    const bitmap = clip
        ? await createImageBitmap(frame, clip[0], clip[1], clip[2], clip[3])
        : await pickRegion(frame);

    if (!bitmap) { toast('已取消区域截图'); return; }
    recognize(bitmap, clip ? '屏幕区域截图' : '屏幕区域截图（手动框选）');
}

/** Fallback for browsers without CropTarget: let the user drag a rectangle. */
function pickRegion(frame) {
    return new Promise((resolve) => {
        const overlay = document.createElement('div');
        overlay.style.cssText = 'position:fixed;inset:0;z-index:20;background:rgba(0,0,0,.55);cursor:crosshair';
        const shot = document.createElement('canvas');
        shot.width = frame.width;
        shot.height = frame.height;
        shot.style.cssText = 'position:absolute;left:50%;top:50%;transform:translate(-50%,-50%);max-width:96vw;max-height:88vh;box-shadow:0 8px 40px rgba(0,0,0,.5)';
        shot.getContext('2d').drawImage(frame, 0, 0);
        const box = document.createElement('div');
        box.style.cssText = 'position:absolute;border:2px solid #07c160;background:rgba(7,193,96,.18);display:none;pointer-events:none';
        const tip = document.createElement('div');
        tip.textContent = '拖动鼠标框选要识别的区域，按 Esc 取消';
        tip.style.cssText = 'position:absolute;left:50%;top:14px;transform:translateX(-50%);padding:8px 14px;border-radius:6px;background:rgba(0,0,0,.75);color:#fff;font-size:13px';
        overlay.append(shot, box, tip);
        document.body.appendChild(overlay);

        let start = null;
        let current = null;
        const toImage = (event) => {
            const rect = shot.getBoundingClientRect();
            return {
                x: (event.clientX - rect.left) * (frame.width / rect.width),
                y: (event.clientY - rect.top) * (frame.height / rect.height)
            };
        };
        const onDown = (event) => {
            start = toImage(event);
            box.style.display = 'block';
            overlay.setPointerCapture(event.pointerId);
        };
        const onMove = (event) => {
            if (!start) { return; }
            current = toImage(event);
            const rect = shot.getBoundingClientRect();
            const scaleX = rect.width / frame.width;
            const scaleY = rect.height / frame.height;
            const left = Math.min(start.x, current.x) * scaleX;
            const top = Math.min(start.y, current.y) * scaleY;
            box.style.left = `${rect.left + left}px`;
            box.style.top = `${rect.top + top}px`;
            box.style.width = `${Math.abs(current.x - start.x) * scaleX}px`;
            box.style.height = `${Math.abs(current.y - start.y) * scaleY}px`;
        };
        const onUp = async (event) => {
            if (!start || !current) { return; }
            onMove(event);
            const x = Math.max(0, Math.round(Math.min(start.x, current.x)));
            const y = Math.max(0, Math.round(Math.min(start.y, current.y)));
            const w = Math.round(Math.abs(current.x - start.x));
            const h = Math.round(Math.abs(current.y - start.y));
            cleanup();
            if (w < 8 || h < 8) { resolve(null); return; }
            resolve(await createImageBitmap(frame, x, y, w, h));
        };
        const onKey = (event) => {
            if (event.key === 'Escape') { cleanup(); resolve(null); }
        };
        function cleanup() {
            overlay.removeEventListener('pointerdown', onDown);
            overlay.removeEventListener('pointermove', onMove);
            overlay.removeEventListener('pointerup', onUp);
            document.removeEventListener('keydown', onKey);
            overlay.remove();
        }
        overlay.addEventListener('pointerdown', onDown);
        overlay.addEventListener('pointermove', onMove);
        overlay.addEventListener('pointerup', onUp);
        document.addEventListener('keydown', onKey);
    });
}

/* ---------------------------------------------------------------- input paths */

async function fromClipboard() {
    if (!navigator.clipboard || !navigator.clipboard.read) {
        showAlert('这个浏览器不允许网页直接读取剪贴板，请按 Ctrl+V 把图片粘贴到本页面。');
        return;
    }
    try {
        const items = await navigator.clipboard.read();
        for (const item of items) {
            const type = item.types.find((t) => t.startsWith('image/'));
            if (type) {
                await recognize(await item.getType(type), '剪贴板图片');
                return;
            }
        }
        toast('剪贴板里没有图片');
    } catch (err) {
        showAlert('读取剪贴板被拒绝，请按 Ctrl+V 把图片粘贴到本页面，或改用「选择文件」。');
    }
}

document.addEventListener('paste', async (event) => {
    const items = event.clipboardData ? event.clipboardData.items : [];
    for (const item of items) {
        if (item.kind === 'file' && item.type.startsWith('image/')) {
            event.preventDefault();
            await recognize(item.getAsFile(), '粘贴的图片');
            return;
        }
    }
});

document.addEventListener('dragover', (event) => {
    event.preventDefault();
    document.body.style.filter = 'brightness(.97)';
});
document.addEventListener('dragleave', () => { document.body.style.filter = ''; });
document.addEventListener('drop', async (event) => {
    event.preventDefault();
    document.body.style.filter = '';
    const file = event.dataTransfer && event.dataTransfer.files[0];
    if (file && file.type.startsWith('image/')) {
        await recognize(file, '拖入的图片');
    } else {
        toast('请拖入图片文件');
    }
});

btnRegion.addEventListener('click', captureRegion);
btnPaste.addEventListener('click', fromClipboard);
document.getElementById('btn-file').addEventListener('click', () => fileInput.click());
document.getElementById('btn-clear').addEventListener('click', () => { chat.innerHTML = ''; });
fileInput.addEventListener('change', async () => {
    const files = Array.from(fileInput.files || []);
    fileInput.value = '';
    for (const file of files) {
        await recognize(file, file.name);
    }
});

/* --------------------------------------------------------------------- boot */

const SAMPLE_LABELS = {
    all: '全部示例图片',
    chat: '示例：聊天截图',
    receipt: '示例：快递单',
    'latin-table': '示例：英文表格',
    'tiny-text': '示例：小字截图'
};

(async function boot() {
    try {
        const response = await fetch('api/health');
        const health = await response.json();
        setEngineState('on', `${health.languages || 'Windows OCR'} · 离线`);
        if (health.hint) { showAlert(health.hint); }
    } catch (err) {
        setEngineState('bad', '未连接');
        showAlert('没有连接到本机识别服务。请在 skill 目录运行 `python scripts/preview.py`，再打开它给出的地址。');
    }
    addRow('bot', '把图片发给我，我读出里面的文字。\n可以点下面的「区域截图」框选屏幕，也可以直接 Ctrl+V 粘贴图片，或选择本地文件。', timeLabel());

    // ?sample=chat|receipt|latin-table|tiny-text|all  → run the bundled
    // reference images through the engine, a one-click self test.
    const sample = new URLSearchParams(location.search).get('sample');
    if (!sample) { return; }
    const names = sample === 'all' ? Object.keys(SAMPLE_LABELS).filter((k) => k !== 'all') : [sample];
    for (const name of names) {
        if (!SAMPLE_LABELS[name]) { continue; }
        try {
            const image = await fetch(`references/sample-${name}.png`).then((r) => {
                if (!r.ok) { throw new Error(`${r.status}`); }
                return r.blob();
            });
            await recognize(image, SAMPLE_LABELS[name]);
        } catch (err) {
            addRow('bot', `读取示例图片失败：${err.message}`, '示例');
        }
    }
})();
