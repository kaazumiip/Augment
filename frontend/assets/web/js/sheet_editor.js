/* Selection uses OSMD source-note identity and individual SVG noteheads. */
let osmd, noteMap = [], selectedIndex = null, queue = Promise.resolve();
let currentXml = initialXml, currentNotes = initialNotes, resizeTimer;
const scoreElement = document.getElementById('score');
const statusElement = document.getElementById('status');
async function loadLibrary() {
  if (window.opensheetmusicdisplay) return;
  await new Promise((resolve, reject) => {
    const script = document.createElement('script');
    script.src = scriptUrl; script.onload = resolve; script.onerror = reject;
    document.head.appendChild(script);
  });
}
function mapNotes(notes) {
  noteMap = [];
  const seen = new Set();
  osmd.cursor.reset();
  for (let count = 0; !osmd.cursor.Iterator.EndReached && count < 100000; count++) {
    for (const graphical of osmd.cursor.GNotesUnderCursor()) {
      const source = graphical.sourceNote;
      if (!source || seen.has(source)) continue;
      seen.add(source);
      const staff = source.ParentStaff;
      const instrument = staff.ParentInstrument;
      const part = osmd.Sheet.Instruments.indexOf(instrument);
      const bar = osmd.Sheet.SourceMeasures.indexOf(source.SourceMeasure);
      const staffNumber = instrument.Staves.indexOf(staff) + 1;
      const onset = source.ParentVoiceEntry.Timestamp.RealValue;
      const voice = String(source.ParentVoiceEntry.ParentVoice.VoiceId);
      const candidates = notes.filter(n => n.part === part && n.bar === bar &&
        n.staff === staffNumber && n.voice === voice && Math.abs(n.onset - onset) < 0.00001 &&
        !noteMap.some(p => p.index === n.index));
      // Pitch uses OSMD's documented octave offset relative to MusicXML.
      const pitch = source.Pitch;
      const midi = pitch ? (pitch.Octave + opensheetmusicdisplay.Pitch.OctaveXmlDifference + 1) * 12 + pitch.FundamentalNote + opensheetmusicdisplay.Pitch.HalfTonesFromAccidental(pitch.Accidental) : null;
      const match = candidates.find(n => n.midi === midi);
      if (!match) continue;
      const heads = graphical.getNoteheadSVGs?.() || [];
      // VexFlow stores the chord's key index on each graphical note.
      const head = heads[graphical.vfnote?.[1] ?? 0] || heads[0] || graphical.getSVGGElement?.();
      if (head) noteMap.push({index:match.index, element:head});
    }
    osmd.cursor.next();
  }
  osmd.cursor.hide();
}
window.selectScoreIndex = function(index) {
  selectedIndex = index;
  const highlight = document.getElementById('selection');
  if (index === null || index === undefined) {
    if (highlight) highlight.style.display = 'none';
    return;
  }
  const selected = noteMap.find(n => n.index === index);
  if (!selected) { if (highlight) highlight.style.display = 'none'; return; }
  const rect = selected.element.getBoundingClientRect();
  if (highlight) {
    Object.assign(highlight.style, {
      display: 'block',
      left: `${rect.left + window.scrollX - 5}px`,
      top: `${rect.top + window.scrollY - 5}px`,
      width: `${Math.max(12, rect.width) + 10}px`,
      height: `${Math.max(12, rect.height) + 10}px`
    });
  }
  try {
    selected.element.scrollIntoView({ behavior: 'smooth', block: 'nearest', inline: 'nearest' });
    setTimeout(() => {
      if (selected.element && highlight) {
        const r2 = selected.element.getBoundingClientRect();
        highlight.style.left = `${r2.left + window.scrollX - 5}px`;
        highlight.style.top = `${r2.top + window.scrollY - 5}px`;
      }
    }, 120);
  } catch (_) {}
};
let down = null, lastTapTime = 0;
scoreElement.addEventListener('pointerdown', e => {
  down = { x: e.clientX, y: e.clientY, time: Date.now() };
});
scoreElement.addEventListener('pointerup', e => {
  if (!down) return;
  const dist = Math.hypot(down.x - e.clientX, down.y - e.clientY);
  const elapsed = Date.now() - down.time;
  down = null;
  if (dist > 18 || elapsed > 700) return;

  const now = Date.now();
  if (now - lastTapTime < 200) return;
  lastTapTime = now;

  let best = null, distance = 40;
  for (const note of noteMap) {
    if (!note.element) continue;
    const r = note.element.getBoundingClientRect();
    const d = Math.hypot(e.clientX - (r.left + r.width / 2), e.clientY - (r.top + r.height / 2));
    if (d < distance) { distance = d; best = note; }
  }
  if (best) {
    window.selectScoreIndex(best.index);
    window.flutter_inappwebview?.callHandler('selectScoreNote', best.index);
  } else {
    window.selectScoreIndex(null);
    window.flutter_inappwebview?.callHandler('selectScoreNote', null);
  }
});
scoreElement.addEventListener('pointercancel', () => { down = null; });
window.addEventListener('pointercancel', () => { down = null; });
window.updateScore = function(xml,notes,index) {
  currentXml = xml; currentNotes = notes; selectedIndex = index;
  queue = queue.catch(() => {}).then(async () => {
    const x=scrollX,y=scrollY;
    try {
      noteMap = [];
      document.getElementById('selection').style.display = 'none';
      await loadLibrary();
      if (!window.opensheetmusicdisplay) {
        throw new Error('OpenSheetMusicDisplay library is not available');
      }
      if (!osmd) {
        osmd = new opensheetmusicdisplay.OpenSheetMusicDisplay(scoreElement, {
          autoResize: true,
          backend: 'svg',
          drawTitle: false,
          drawSubtitle: false,
          drawComposer: false,
          drawCredits: false,
          drawPartNames: false,
          drawPartAbbreviations: false,
          pageFormat: 'A4_P',
        });
      }
      await osmd.load(xml);
      if (osmd.EngravingRules) {
        osmd.EngravingRules.RenderPartNames = false;
        osmd.EngravingRules.RenderPartAbbreviations = false;
      }
      if (osmd.DrawingParameters) {
        osmd.DrawingParameters.DrawPartNames = false;
      }
      const small = innerWidth < 360;
      osmd.zoom = small ? 0.46 : 0.60;
      osmd.render(); mapNotes(notes);
      statusElement.style.display='none';
      window.scrollTo(x,y); window.selectScoreIndex(index);
    } catch (e) {
      console.error('Sheet editor render error:', e);
      statusElement.textContent='Could not display the sheet. Reopen the editor to retry.';
      statusElement.style.display='block';
      throw e;
    }
  });
  return queue;
};
let lastWidth = window.innerWidth;
window.addEventListener('resize', () => {
  if (Math.abs(window.innerWidth - lastWidth) < 12) {
    if (selectedIndex !== null) {
      window.selectScoreIndex(selectedIndex);
    }
    return;
  }
  lastWidth = window.innerWidth;
  clearTimeout(resizeTimer);
  resizeTimer = setTimeout(() => window.updateScore(currentXml, currentNotes, selectedIndex), 150);
});
window.updateScore(initialXml, initialNotes, null);
