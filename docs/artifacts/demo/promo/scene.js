/* DSH Mobile promo — deterministic timeline (t in seconds). */
(() => {
  'use strict';

  const DURATION = 21.6;
  const SCALE = 0.9;
  const $ = (s) => document.querySelector(s);
  const $$ = (s) => Array.from(document.querySelectorAll(s));

  const clamp01 = (v) => Math.min(1, Math.max(0, v));
  const seg = (t, a, b) => clamp01((t - a) / (b - a || 1e-6));
  const lerp = (a, b, p) => a + (b - a) * p;
  const eOut = (p) => 1 - Math.pow(1 - p, 3);
  const eInOut = (p) => (p < 0.5 ? 4 * p * p * p : 1 - Math.pow(-2 * p + 2, 3) / 2);
  const eOutExpo = (p) => (p >= 1 ? 1 : 1 - Math.pow(2, -9 * p));
  const win = (t, a, ai, b, bo) => clamp01(eOut(seg(t, a, a + ai)) * (1 - eOut(seg(t, b, b + bo))));

  /* The phone story is authored on its own 0–19.6s timeline, then compressed
     into the second half of the film so the desktop can register first. */
  const PHONE_START = 3.4;
  const WARP = [
    [0, 4.4, 0, 5.55],
    [4.4, 7.9, 5.55, 9.9],
    [7.9, 11.3, 9.9, 13.95],
    [11.3, 14.5, 13.95, 17.5],
    [14.5, 16.4, 17.5, 19.6],
  ];
  function warp(tp) {
    if (tp <= 0) return 0;
    for (const [a, b, c, d] of WARP) {
      if (tp <= b) return c + ((tp - a) / (b - a)) * (d - c);
    }
    return 19.6 + (tp - 16.4);
  }

  /* ---------- element cache ---------- */
  const E = {};
  [
    'camera', 'float', 'stage', 'statusbar', 'scanner', 'scanbeam', 'scanok', 'flash',
    'viewChat', 'viewFiles', 'viewPair', 'steps', 'stepFill',
    'endcard', 'toast', 'savedAct', 'codeVal', 'segInd', 'paneBrowse', 'paneChanges', 'crumb',
    'dlSheet', 'dlFill', 'dlBytes', 'dlPct', 'dlDone', 'dlBtn', 'diffSheet', 'paneHistory', 'segHistory',
    'm1', 'm2', 'tool1', 'tcSpin', 'tcCheck', 'tcFoot', 'tcState', 'm3', 'm3text', 'm3caret', 'resultChip',
    'statusline', 'scanbtn', 'csvRow', 'clientRow', 'searchPh', 'finder', 'seg', 'fade', 'pairCta', 'scrim',
    'desktop', 'dw', 'dwModal', 'dwScrim', 'dwmUnreg', 'dwmReg', 'dwRegBtn', 'dwRegText', 'dwRegSpin',
    'dwConn', 'dwDot', 'cursor', 'clickring', 'actHead', 'actAnnots', 'panelSpin',
  ].forEach((k) => { E[k] = document.getElementById(k); });
  E.viewChat = document.getElementById('view-chat');
  E.viewFiles = document.getElementById('view-files');
  E.viewPair = document.getElementById('view-pair');
  E.heads = $$('.head');
  E.eyebrow = $('.eyebrow');
  E.annots = $$('.an');
  E.subs = $$('.sub');
  E.stepItems = $$('.step');
  E.rows = $$('#paneBrowse .row.file');
  E.crows = $$('#paneChanges .crow, #paneChanges .group, #paneChanges .branch');
  E.dlines = $$('#diffSheet .dline');
  E.commits = $$('#paneHistory .commit');
  E.ripples = [document.getElementById('rip1'), document.getElementById('rip2'), document.getElementById('rip3'), document.getElementById('rip4')];

  /* ---------- one-time measurement ---------- */
  let TAPS = {
    scan: { x: 195, y: 430 }, csv: { x: 195, y: 520 }, client: { x: 195, y: 600 },
    folder: { x: 340, y: 80 }, conn: { x: 84, y: 505 }, reg: { x: 400, y: 450 },
  };
  function measure() {
    const cam = E.camera, fl = E.float, vc = E.viewChat, vf = E.viewFiles, dw = E.dw;
    const saved = [cam.style.transform, fl.style.transform, vc.style.transform, vf.style.transform, dw.style.transform];
    cam.style.transform = 'none';
    fl.style.transform = 'none';
    vc.style.transform = 'none';
    vf.style.transform = 'none';
    dw.style.transform = 'none';
    const sr = document.getElementById('screen').getBoundingClientRect();
    const read = (sel) => {
      const r = document.querySelector(sel).getBoundingClientRect();
      return {
        x: (r.left + r.width / 2 - sr.left) / SCALE,
        y: (r.top + r.height / 2 - sr.top) / SCALE,
      };
    };
    TAPS = {
      scan: read('#scanbtn'), csv: read('#csvRow'), client: read('#clientRow'), folder: read('#chatFolder'),
    };
    const dr = E.desktop.getBoundingClientRect();
    const dRead = (sel) => {
      const r = document.querySelector(sel).getBoundingClientRect();
      return { x: r.left + r.width / 2 - dr.left, y: r.top + r.height / 2 - dr.top };
    };
    TAPS.conn = dRead('#dwConn');
    TAPS.reg = dRead('#dwRegBtn');
    [cam.style.transform, fl.style.transform, vc.style.transform, vf.style.transform, dw.style.transform] = saved;
  }

  /* ---------- phone camera keyframes (phone timeline) ---------- */
  const CAM = [
    { t: 0.0, z: 0.965, fx: 0.5, fy: 0.5, ax: 960, ay: 402 },
    { t: 1.5, z: 1.0, fx: 0.5, fy: 0.5, ax: 960, ay: 400 },
    { t: 2.35, z: 1.04, fx: 0.5, fy: 0.5, ax: 972, ay: 400 },
    { t: 2.85, z: 1.42, fx: 0.5, fy: 0.4, ax: 1000, ay: 392 },
    { t: 4.0, z: 1.42, fx: 0.5, fy: 0.4, ax: 1000, ay: 392 },
    { t: 4.65, z: 1.05, fx: 0.5, fy: 0.5, ax: 972, ay: 400 },
    { t: 5.55, z: 1.0, fx: 0.5, fy: 0.5, ax: 960, ay: 400 },
    { t: 6.05, z: 1.42, fx: 0.5, fy: 0.3, ax: 1000, ay: 396 },
    { t: 9.55, z: 1.42, fx: 0.5, fy: 0.3, ax: 1000, ay: 396 },
    { t: 10.05, z: 1.04, fx: 0.5, fy: 0.5, ax: 975, ay: 400 },
    { t: 10.65, z: 1.4, fx: 0.5, fy: 0.28, ax: 1000, ay: 394 },
    { t: 11.55, z: 1.4, fx: 0.5, fy: 0.6, ax: 1000, ay: 410 },
    { t: 13.4, z: 1.4, fx: 0.5, fy: 0.62, ax: 1000, ay: 410 },
    { t: 14.0, z: 1.06, fx: 0.5, fy: 0.5, ax: 975, ay: 400 },
    { t: 14.6, z: 1.3, fx: 0.5, fy: 0.3, ax: 1000, ay: 396 },
    { t: 15.75, z: 1.46, fx: 0.5, fy: 0.62, ax: 1000, ay: 400 },
    { t: 16.95, z: 1.46, fx: 0.5, fy: 0.62, ax: 1000, ay: 400 },
    { t: 18.25, z: 1.0, fx: 0.5, fy: 0.5, ax: 1000, ay: 400 },
    { t: 19.6, z: 1.0, fx: 0.5, fy: 0.5, ax: 1000, ay: 400 },
  ];
  function camAt(t) {
    let i = 0;
    while (i < CAM.length - 2 && t > CAM[i + 1].t) i++;
    const a = CAM[i], b = CAM[i + 1];
    const p = eInOut(seg(t, a.t, b.t));
    return {
      z: lerp(a.z, b.z, p),
      fx: lerp(a.fx, b.fx, p),
      fy: lerp(a.fy, b.fy, p),
      ax: lerp(a.ax, b.ax, p),
      ay: lerp(a.ay, b.ay, p),
    };
  }

  /* ---------- left copy ---------- */
  const HEADS = [
    { el: E.heads[0], inT: 99, outT: 99 },
    { el: E.heads[1], inT: 6.9, outT: 8.2 },
    { el: E.heads[2], inT: 8.4, outT: 11.5 },
    { el: E.heads[3], inT: 11.7, outT: 14.9 },
    { el: E.heads[4], inT: 15.1, outT: 17.3 },
    { el: E.heads[5], inT: 17.45, outT: 19.6 },
  ];
  const SUBS = [
    { el: E.subs[0], inT: 99, outT: 99 },
    { el: E.subs[1], inT: 7.0, outT: 8.2 },
    { el: E.subs[2], inT: 8.55, outT: 11.5 },
    { el: E.subs[3], inT: 11.85, outT: 14.9 },
    { el: E.subs[4], inT: 15.25, outT: 17.3 },
    { el: E.subs[5], inT: 17.6, outT: 19.6 },
  ];
  const TYPE_FULL = '共 12,480 行，重复 36 行，已生成报告。';
  const TYPE_CHARS = Array.from(TYPE_FULL);

  function setText(node, txt) {
    if (node.textContent !== txt) node.textContent = txt;
  }

  function ringAt(t, at, pt) {
    if (!pt) return;
    const p = seg(t, at, at + 0.46);
    if (t >= at && t < at + 0.5) {
      E.clickring.style.opacity = String((1 - p) * 0.8);
      E.clickring.style.left = `${pt.x}px`;
      E.clickring.style.top = `${pt.y}px`;
      E.clickring.style.transform = `scale(${0.3 + 1.9 * eOut(p)})`;
    } else {
      E.clickring.style.opacity = '0';
    }
  }

  /* ---------- main seek ---------- */
  function seek(t) {
    t = Math.max(0, Math.min(DURATION, t));
    const tp = warp(Math.max(0, t - PHONE_START));

    /* ================= desktop act ================= */
    const deskIn = eOut(seg(t, 0.08, 0.78));
    const deskOut = eInOut(seg(t, 6.7, 7.3));
    E.desktop.style.opacity = String(deskIn * (1 - deskOut));
    E.dw.style.transform = `translateY(${(1 - deskIn) * 22}px) scale(${lerp(0.985, 1, deskIn)})`;

    const modalP = eOut(seg(t, 1.42, 1.78));
    E.dwModal.style.opacity = String(modalP);
    E.dwModal.style.transform = `translateY(${(1 - modalP) * 10}px) scale(${lerp(0.97, 1, modalP)})`;
    E.dwScrim.style.opacity = String(0.55 * modalP);

    const connPress = win(t, 1.33, 0.05, 1.48, 0.18);
    E.dwConn.style.background = connPress > 0 ? `rgba(17,20,24,${0.06 * connPress})` : '';

    const cFrom = { x: 706, y: 512 };
    const toConn = eInOut(seg(t, 0.82, 1.3));
    const toReg = eInOut(seg(t, 1.86, 2.32));
    const px = lerp(lerp(cFrom.x, TAPS.conn.x, toConn), TAPS.reg.x, toReg);
    const py = lerp(lerp(cFrom.y, TAPS.conn.y, toConn), TAPS.reg.y, toReg);
    E.cursor.style.transform = `translate(${px - 2}px, ${py - 2}px)`;
    E.cursor.style.opacity = String(win(t, 0.8, 0.16, 2.55, 0.2));
    ringAt(t, 1.36, TAPS.conn);
    ringAt(t, 2.38, TAPS.reg);

    const regBusy = t >= 2.38 && t < 2.98;
    E.panelSpin.style.opacity = regBusy ? '1' : '0';
    E.panelSpin.querySelector('i').style.transform = `rotate(${(t * 640) % 360}deg)`;
    E.dwRegBtn.style.transform = `scale(${1 - 0.03 * win(t, 2.36, 0.06, 2.48, 0.12)})`;

    const grow = eInOut(seg(t, 2.95, 3.4));
    E.dwModal.style.height = `${lerp(241, 509, grow)}px`;
    const swapIn = eOut(seg(t, 2.95, 3.15));
    E.dwmUnreg.style.opacity = String(1 - swapIn);
    E.dwmReg.style.opacity = String(swapIn);
    E.dwDot.style.background = t >= 3.0 ? '#1F9D55' : '#C2C7CF';
    E.dwDot.style.boxShadow = t >= 3.0 ? '0 0 0 3px rgba(31,157,85,.14)' : 'none';

    /* ================= phone ================= */
    const c = camAt(tp);
    let cz = c.z, cfy = c.fy, cax = c.ax, cay = c.ay;
    if (t >= 17.35) {
      const hp = eInOut(seg(t, 17.35, 17.75));
      const ep = eInOut(seg(t, 19.8, 20.7));
      cz = lerp(lerp(1.46, 1.34, hp), 1.0, ep);
      cfy = lerp(lerp(0.62, 0.3, hp), 0.5, ep);
      cax = 1000;
      cay = lerp(lerp(400, 396, hp), 400, ep);
    }
    const Cx = 779 + 351 * 0.5;
    const Cy = 22 + 759.6 * cfy;
    if (t < 7.4) {
      E.camera.style.transform = 'none';
    } else {
      E.camera.style.transformOrigin = `${Cx}px ${Cy}px`;
      E.camera.style.transform = `translate(${cax - Cx}px, ${cay - Cy}px) scale(${cz})`;
    }

    const endP = eInOut(seg(t, 19.9, 20.7));
    if (t < 7.4) {
      const ap = eInOut(seg(t, 4.2, 6.5));
      const st = eInOut(seg(t, 6.5, 7.4));
      const ws = lerp(lerp(0.45, 0.9, ap), 1, st);
      const wx = lerp(lerp(1170, 980, ap), 965, st);
      const wy = lerp(lerp(300, 470, ap), 402, st);
      const wr = lerp(-10, 0, ap);
      E.float.style.transform = `translate(${wx - 965}px, ${wy - 402}px) scale(${ws}) rotate(${wr}deg)`;
      E.float.style.opacity = String(clamp01(seg(t, 4.2, 4.45)) * lerp(1, 0.32, endP));
    } else {
      E.float.style.transform = `translate(${endP * 112}px, 0px) rotate(${-endP * 7}deg) scale(${lerp(1, 0.95, endP)})`;
      E.float.style.opacity = String(lerp(1, 0.32, endP));
    }
    E.float.style.filter = `brightness(${1 - 0.22 * endP}) saturate(${1 - 0.18 * endP})`;

    const actP = 1 - eOut(seg(t, 6.35, 6.75));
    E.actHead.style.opacity = String(actP);
    E.actHead.style.transform = `translateY(${-(1 - actP) * 10}px)`;
    const copyOn = eOut(seg(t, 6.75, 7.15));
    E.eyebrow.style.opacity = String(copyOn);
    E.annots.forEach((n, i) => {
      const p = eOut(seg(t, 3.4 + i * 0.35, 3.75 + i * 0.35));
      const q = eOut(seg(t, 6.2, 6.5));
      n.style.opacity = String(p * (1 - q));
      n.style.transform = `translateX(${(1 - p) * -12}px)`;
    });

    /* left copy */
    HEADS.forEach((h) => {
      const p = eOut(seg(t, h.inT, h.inT + 0.5));
      const q = eOut(seg(t, h.outT, h.outT + 0.36));
      h.el.style.opacity = String(clamp01(p * (1 - q)) * copyOn);
      h.el.style.transform = `translateY(${(1 - p) * 18 - q * 14}px)`;
    });
    SUBS.forEach((s) => {
      const p = eOut(seg(t, s.inT, s.inT + 0.5));
      const q = eOut(seg(t, s.outT, s.outT + 0.32));
      s.el.style.opacity = String(clamp01(p * (1 - q)) * copyOn);
      s.el.style.transform = `translateY(${(1 - p) * 14 - q * 10}px)`;
    });

    /* steps */
    const stepsIn = eOut(seg(t, 7.85, 8.25));
    const stepsOut = eOut(seg(t, 19.65, 19.95));
    E.steps.style.opacity = String(clamp01(stepsIn * (1 - stepsOut)));
    E.steps.style.transform = `translateY(${(1 - stepsIn) * 16}px)`;
    const active = t < 11.5 ? 2 : t < 14.9 ? 3 : t < 17.35 ? 4 : 5;
    E.stepItems.forEach((n, i) => {
      n.classList.toggle('on', i + 1 === active);
      n.classList.toggle('done', i + 1 < active);
    });
    let fill = 20;
    if (t > 11.5) fill = lerp(20, 40, eInOut(seg(t, 11.5, 11.9)));
    if (t > 14.9) fill = lerp(40, 60, eInOut(seg(t, 14.9, 15.3)));
    if (t > 17.35) fill = lerp(60, 80, eInOut(seg(t, 17.35, 17.75)));
    if (t > 19.6) fill = lerp(80, 100, eInOut(seg(t, 19.6, 19.9)));
    E.stepFill.style.height = `${fill}%`;

    /* endcard */
    const enIn = eOut(seg(t, 19.75, 20.35));
    E.endcard.style.opacity = String(enIn);
    E.endcard.style.transform = `translateY(${(1 - enIn) * 26}px)`;

    /* scanner */
    const up = eOut(seg(tp, 2.3, 2.72));
    const down = eOut(seg(tp, 4.12, 4.5));
    const shown = clamp01(up - down);
    E.scanner.style.transform = `translateY(${100 * (1 - shown)}%)`;
    E.scrim.style.opacity = String(0.55 * shown);
    const barCovered = 844 * (1 - shown) < 54;
    E.statusbar.style.color = barCovered ? '#FFFFFF' : '#0F1115';
    const beamOn = tp > 2.9 && tp < 3.88;
    E.scanbeam.style.opacity = beamOn ? '0.95' : '0';
    if (beamOn) {
      const f = ((tp - 2.9) % 0.82) / 0.82;
      E.scanbeam.style.top = `${14 + 214 * f}px`;
    }
    const fp = seg(tp, 3.88, 4.16);
    E.flash.style.opacity = tp > 3.88 && tp < 4.16 ? String(Math.sin(fp * Math.PI) * 0.55) : '0';
    E.finder.classList.toggle('detected', tp >= 3.88);
    const okO = win(tp, 3.9, 0.25, 4.3, 0.2);
    E.scanok.style.opacity = String(okO);
    E.scanok.style.transform = `translate(-50%, ${(1 - eOut(seg(tp, 3.9, 4.15))) * 10}px)`;

    /* view stack */
    const chatP = eInOut(seg(tp, 5.9, 6.4));
    const filesP = eInOut(seg(tp, 9.95, 10.45));
    E.viewChat.style.transform = `translateX(${100 * (1 - chatP) - 24 * filesP}%)`;
    E.viewFiles.style.transform = `translateX(${100 * (1 - filesP)}%)`;
    E.viewPair.style.transform = `translateX(${-22 * chatP}%)`;

    /* pairing state */
    const toastO = win(tp, 4.5, 0.3, 5.45, 0.22);
    E.toast.style.opacity = String(toastO);
    E.toast.style.transform = `translate(-50%, ${-14 + 14 * eOut(seg(tp, 4.5, 4.8))}px)`;
    const connected = tp >= 4.55;
    E.savedAct.classList.toggle('on', connected);
    setText(E.savedAct, connected ? '已连接' : '连接');
    E.codeVal.style.opacity = tp >= 4.4 ? String(eOut(seg(tp, 4.4, 4.7))) : '0';
    E.pairCta.style.opacity = connected ? '0.5' : '1';
    document.getElementById('codePh').style.opacity = tp >= 4.4 ? '0' : '1';

    /* chat */
    const m1p = eOut(seg(tp, 6.35, 6.7));
    E.m1.style.opacity = String(m1p);
    E.m1.style.transform = `translateY(${(1 - m1p) * 10}px)`;
    const m2p = eOut(seg(tp, 6.68, 7.0));
    E.m2.style.opacity = String(m2p);
    E.m2.style.transform = `translateY(${(1 - m2p) * 10}px)`;
    const toolP = eOut(seg(tp, 6.86, 7.2));
    E.tool1.style.opacity = String(toolP);
    E.tool1.style.transform = `translateY(${(1 - toolP) * 12}px) scale(${lerp(0.985, 1, toolP)})`;
    const running = tp < 7.82;
    E.tcSpin.style.opacity = running ? '1' : '0';
    E.tcSpin.style.transform = `rotate(${(tp * 720) % 360}deg)`;
    E.tcState.style.opacity = running ? '1' : '0';
    E.tcCheck.style.opacity = running ? '0' : '1';
    E.tcFoot.style.opacity = running ? '0' : '1';
    const rcP = eOut(seg(tp, 7.95, 8.3));
    E.resultChip.style.opacity = String(rcP);
    E.resultChip.style.transform = `translateY(${(1 - rcP) * 10}px)`;
    const typed = Math.round(TYPE_CHARS.length * seg(tp, 8.25, 9.3));
    setText(E.m3text, TYPE_CHARS.slice(0, typed).join(''));
    const caretOn = tp > 8.2 && tp < 9.62;
    E.m3caret.style.opacity = caretOn ? (Math.floor(tp * 3.2) % 2 === 0 ? '1' : '0') : '0';
    const slP = eOut(seg(tp, 9.3, 9.62));
    E.statusline.style.opacity = String(slP);
    E.statusline.style.transform = `translateY(${(1 - slP) * 8}px)`;

    /* files */
    E.rows.forEach((r, i) => {
      const p = eOut(seg(tp, 10.55 + i * 0.045, 10.9 + i * 0.045));
      r.style.opacity = String(p);
      r.style.transform = `translateX(${(1 - p) * 10}px)`;
    });
    const csvPulse = win(tp, 11.24, 0.1, 11.7, 0.4);
    E.csvRow.style.background = csvPulse > 0 ? `rgba(77,107,254,${0.055 * csvPulse})` : '';

    const segW = E.seg.clientWidth;
    const indW = (segW - 6) / 3;
    E.segInd.style.width = `${indW}px`;
    const slide = eInOut(seg(tp, 13.98, 14.3));
    const hist = eInOut(seg(t, 17.2, 17.55));
    const pos = Math.min(2, slide + hist);
    E.segInd.style.transform = `translateX(${indW * pos}px)`;
    document.getElementById('segBrowse').classList.toggle('on', pos < 0.5);
    document.getElementById('segChanges').classList.toggle('on', pos >= 0.5 && pos < 1.5);
    E.segHistory.classList.toggle('on', pos >= 1.5);
    E.paneBrowse.style.opacity = String(Math.max(0, 1 - pos));
    E.paneChanges.style.opacity = String(pos < 1 ? pos : Math.max(0, 2 - pos));
    E.paneHistory.style.opacity = String(Math.max(0, pos - 1));
    E.paneChanges.style.top = `${240 - 31 * Math.min(pos, 1)}px`;
    E.paneHistory.style.top = `${240 - 31 * Math.min(pos, 1)}px`;
    E.paneBrowse.style.top = '240px';
    E.crumb.style.opacity = String(1 - Math.min(pos, 1));
    setText(E.searchPh, pos < 0.5 ? '搜索当前目录' : pos < 1.5 ? '搜索变更路径' : '搜索提交信息');
    E.commits.forEach((r, i) => {
      const p = eOut(seg(t, 17.55 + i * 0.05, 17.9 + i * 0.05));
      r.style.opacity = String(p);
      r.style.transform = `translateX(${(1 - p) * 8}px)`;
    });
    E.crows.forEach((r, i) => {
      const p = eOut(seg(tp, 14.3 + i * 0.035, 14.66 + i * 0.035));
      r.style.opacity = String(p);
      r.style.transform = `translateX(${(1 - p) * 8}px)`;
    });
    const cliPulse = win(tp, 15.54, 0.1, 15.95, 0.4);
    E.clientRow.style.background = cliPulse > 0 ? `rgba(77,107,254,${0.06 * cliPulse})` : '';

    const dlUp = eOut(seg(tp, 11.52, 11.82));
    const dlDown = eOut(seg(tp, 13.9, 14.18));
    E.dlSheet.style.transform = `translateY(${((1 - dlUp) + dlDown) * 112}%)`;
    const dlP = eInOut(seg(tp, 11.8, 13.02));
    E.dlFill.style.width = `${dlP * 100}%`;
    setText(E.dlBytes, `${(59.1 * dlP).toFixed(1)} MB / 59.1 MB`);
    setText(E.dlPct, `${Math.round(dlP * 100)}%`);
    E.dlDone.style.opacity = String(eOut(seg(tp, 13.08, 13.34)));
    E.dlBtn.style.opacity = String(eOut(seg(tp, 13.24, 13.5)));

    const dfUp = eOut(seg(tp, 15.7, 16.03));
    const dfDown = eOut(seg(tp, 16.55, 16.85));
    E.diffSheet.style.transform = `translateY(${((1 - dfUp) + dfDown) * 112}%)`;
    E.dlines.forEach((r, i) => {
      const p = eOut(seg(tp, 16.06 + i * 0.055, 16.32 + i * 0.055));
      r.style.opacity = String(p);
    });

    /* loop fade */
    const fadeOut = eInOut(seg(t, 21.3, 21.6));
    const fadeIn = 1 - eOut(seg(t, 0, 0.3));
    E.fade.style.opacity = String(Math.max(fadeOut, fadeIn));

    /* phone tap ripples */
    const ripple = (el, tap, pt) => {
      if (!pt) { el.style.opacity = '0'; return; }
      const p = seg(tp, tap, tap + 0.62);
      el.style.left = `${pt.x}px`;
      el.style.top = `${pt.y}px`;
      el.style.opacity = tp >= tap && tp < tap + 0.62 ? String((1 - p) * 0.4) : '0';
      el.style.transform = `scale(${0.4 + 2.0 * eOut(p)})`;
    };
    ripple(E.ripples[0], 2.06, TAPS.scan);
    ripple(E.ripples[1], 11.25, TAPS.csv);
    ripple(E.ripples[2], 15.55, TAPS.client);
    ripple(E.ripples[3], 9.82, TAPS.folder);
    const fPress = win(tp, 9.8, 0.06, 9.9, 0.12);
    document.getElementById('chatFolder').style.transform = `scale(${1 - 0.08 * fPress})`;
  }

  /* ---------- boot ---------- */
  function boot() {
    measure();
    window.seek = seek;
    window.DURATION = DURATION;
    seek(0);
    window.__ready = true;
  }
  if (document.fonts && document.fonts.ready) {
    document.fonts.ready.then(() => requestAnimationFrame(boot));
  } else {
    requestAnimationFrame(boot);
  }
})();
