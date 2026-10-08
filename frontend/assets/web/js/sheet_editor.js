/* Selection uses OSMD source-note identity and individual SVG noteheads. */
let osmd, noteMap = [], selectedIndex = null, queue = Promise.resolve();
let currentXml = initialXml, currentNotes = initialNotes, resizeTimer;
let isRendering = false, pendingUpdate = null;
const scoreElement = document.getElementById('score');
const statusElement = document.getElementById('status');

async function loadLibrary() {
  if (window.opensheetmusicdisplay) return;
  await new Promise((resolve, reject) => {
    const script = document.createElement('script');
    script.src = scriptUrl;
    script.onload = resolve;
    script.onerror = reject;
    document.head.appendChild(script);
  });
}

function mapNotes(notes) {
  const newMap = [];
  if (!osmd || !notes || !notes.length) return;
  const seen = new Set();
  try {
    osmd.cursor.reset();
  } catch (_) {
    return;
  }

  for (let count = 0; !osmd.cursor.Iterator.EndReached && count < 100000; count++) {
    let gNotes = [];
    try {
      gNotes = osmd.cursor.GNotesUnderCursor() || [];
    } catch (_) {}

    for (const graphical of gNotes) {
      if (!graphical) continue;
      const source = graphical.sourceNote;
      if (!source || seen.has(source)) continue;
      seen.add(source);

      const staff = source.ParentStaff;
      const instrument = staff?.ParentInstrument;
      const part = instrument ? osmd.Sheet.Instruments.indexOf(instrument) : 0;
      const bar = source.SourceMeasure ? osmd.Sheet.SourceMeasures.indexOf(source.SourceMeasure) : 0;
      const staffNumber = (instrument && staff) ? instrument.Staves.indexOf(staff) + 1 : 1;
      const onset = source.ParentVoiceEntry?.Timestamp?.RealValue ?? 0;
      const voice = String(source.ParentVoiceEntry?.ParentVoice?.VoiceId ?? '1');

      const candidates = notes.filter(n =>
        n.part === part &&
        n.bar === bar &&
        n.staff === staffNumber &&
        n.voice === voice &&
        Math.abs(n.onset - onset) < 0.001 &&
        !newMap.some(p => p.index === n.index)
      );

      if (candidates.length === 0) continue;

      // Pitch uses OSMD's documented octave offset relative to MusicXML.
      let midi = null;
      const pitch = source.Pitch;
      if (pitch) {
        try {
          if (typeof pitch.getHalfTone === 'function') {
            midi = pitch.getHalfTone() + 12;
          } else {
            const accHalf = (pitch.Accidental !== undefined && window.opensheetmusicdisplay?.Pitch?.HalfTonesFromAccidental)
              ? (window.opensheetmusicdisplay.Pitch.HalfTonesFromAccidental(pitch.Accidental) || 0)
              : 0;
            midi = (pitch.Octave + (window.opensheetmusicdisplay?.Pitch?.OctaveXmlDifference || 3) + 1) * 12 +
                   (pitch.FundamentalNote || 0) + accHalf;
          }
        } catch (_) {
          midi = null;
        }
      }

      let match = null;
      if (candidates.length === 1) {
        // Single note at this onset in this voice/bar is an exact match
        match = candidates[0];
      } else {
        if (midi !== null) {
          match = candidates.find(n => n.midi === midi);
        }
        if (!match && midi !== null) {
          let bestDiff = Infinity;
          for (const cand of candidates) {
            if (cand.midi !== null && cand.midi !== undefined) {
              const diff = Math.abs(cand.midi - midi);
              if (diff < bestDiff) {
                bestDiff = diff;
                match = cand;
              }
            }
          }
        }
        if (!match) {
          match = candidates[0];
        }
      }

      if (!match) continue;

      let head = null;
      try {
        const heads = (typeof graphical.getNoteheadSVGs === 'function') ? graphical.getNoteheadSVGs() : [];
        head = heads[graphical.vfnote?.[1] ?? 0] || heads[0];
        if (!head && typeof graphical.getSVGGElement === 'function') {
          head = graphical.getSVGGElement();
        }
        if (!head && typeof graphical.getVFNoteSVG === 'function') {
          head = graphical.getVFNoteSVG();
        }
      } catch (_) {}

      if (head) {
        newMap.push({ index: match.index, element: head });
      }
    }

    try {
      osmd.cursor.next();
    } catch (_) {
      break;
    }
  }

  try {
    osmd.cursor.hide();
  } catch (_) {}

  // Replace noteMap atomically so taps in flight don't experience an empty map
  if (newMap.length > 0) {
    noteMap = newMap;
  }
}

window.selectScoreIndex = function(index, shouldScroll = false) {
  selectedIndex = index;
  const highlight = document.getElementById('selection');
  if (index === null || index === undefined) {
    if (highlight) highlight.style.display = 'none';
    return;
  }
  const selected = noteMap.find(n => n.index === index);
  if (!selected) {
    if (highlight) highlight.style.display = 'none';
    return;
  }
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

  // Only scroll into view if explicitly requested or if element is completely out of view
  const inView = rect.top >= 0 && rect.bottom <= window.innerHeight &&
                 rect.left >= 0 && rect.right <= window.innerWidth;
  if (shouldScroll || !inView) {
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
  }
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
  if (dist > 30 || elapsed > 900) return;

  const now = Date.now();
  if (now - lastTapTime < 60) return;
  lastTapTime = now;

  let best = null;

  // 1. Direct hit-test: did user tap on or inside a note element or note group?
  let target = e.target;
  while (target && target !== scoreElement && target !== document.body) {
    const direct = noteMap.find(n => n.element === target || (n.element.contains && n.element.contains(target)));
    if (direct) {
      best = direct;
      break;
    }
    const parentNote = noteMap.find(n => {
      const parent = n.element.closest?.('.vf-stavenote, .vf-note, g');
      return parent && (parent === target || parent.contains(target));
    });
    if (parentNote) {
      best = parentNote;
      break;
    }
    target = target.parentElement;
  }

  // 2. Proximity search: find closest notehead within generous 55px radius
  if (!best) {
    let distance = 55;
    for (const note of noteMap) {
      if (!note.element) continue;
      const r = note.element.getBoundingClientRect();
      if (r.width === 0 && r.height === 0) continue;
      const d = Math.hypot(e.clientX - (r.left + r.width / 2), e.clientY - (r.top + r.height / 2));
      if (d < distance) {
        distance = d;
        best = note;
      }
    }
  }

  if (best) {
    window.selectScoreIndex(best.index, false);
    window.flutter_inappwebview?.callHandler('selectScoreNote', best.index);
  } else {
    // Only deselect if clearly tapped on empty space
    window.selectScoreIndex(null);
    window.flutter_inappwebview?.callHandler('selectScoreNote', null);
  }
});

scoreElement.addEventListener('pointercancel', () => { down = null; });
window.addEventListener('pointercancel', () => { down = null; });

window.updateScore = function(xml, notes, index) {
  currentXml = xml;
  currentNotes = notes;
  selectedIndex = index;

  if (isRendering) {
    pendingUpdate = { xml, notes, index };
    return queue;
  }

  isRendering = true;
  queue = (async () => {
    try {
      while (true) {
        const targetXml = currentXml;
        const targetNotes = currentNotes;
        const targetIndex = selectedIndex;
        pendingUpdate = null;

        const x = window.scrollX, y = window.scrollY;
        try {
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
          await osmd.load(targetXml);
          if (osmd.EngravingRules) {
            osmd.EngravingRules.RenderPartNames = false;
            osmd.EngravingRules.RenderPartAbbreviations = false;
          }
          if (osmd.DrawingParameters) {
            osmd.DrawingParameters.DrawPartNames = false;
          }
          const small = window.innerWidth < 360;
          osmd.zoom = small ? 0.46 : 0.60;
          osmd.render();
          mapNotes(targetNotes);
          statusElement.style.display = 'none';
          window.scrollTo(x, y);
          if (targetIndex !== null && targetIndex !== undefined) {
            window.selectScoreIndex(targetIndex, false);
          }
        } catch (e) {
          console.error('Sheet editor render error:', e);
        }

        if (!pendingUpdate && targetXml === currentXml && targetNotes === currentNotes) {
          break;
        }
      }
    } finally {
      isRendering = false;
    }
  })();
  return queue;
};

let lastWidth = window.innerWidth;
window.addEventListener('resize', () => {
  if (Math.abs(window.innerWidth - lastWidth) < 12) {
    if (selectedIndex !== null) {
      window.selectScoreIndex(selectedIndex, false);
    }
    return;
  }
  lastWidth = window.innerWidth;
  clearTimeout(resizeTimer);
  resizeTimer = setTimeout(() => window.updateScore(currentXml, currentNotes, selectedIndex), 150);
});

window.updateScore(initialXml, initialNotes, null);
