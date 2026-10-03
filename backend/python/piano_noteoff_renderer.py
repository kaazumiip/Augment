"""Preserve the newest same-key attack when an older MIDI release arrives.

Rendering only: never edits notes, pedal, arrangement, or performance MIDI.
One physical piano key is retriggered normally; an obsolete release must not
release its newer attack. Different keys retain ordinary polyphonic behavior.
"""
import numpy as np
from pretty_midi.fluidsynth import get_fluidsynth_instance


def has_same_key_overlap(instrument):
    ends = {}
    for n in sorted(instrument.notes, key=lambda n:n.start):
        if n.start < ends.get(n.pitch, -1):
            return True
        ends[n.pitch] = max(n.end, ends.get(n.pitch, -1))
    return False


def owned_note_events(instrument):
    """Yield ordinary synth events, suppressing only obsolete note-offs."""
    events=[]
    for identity,n in enumerate(instrument.notes):
        events.extend([(n.start,'note on',n.pitch,n.velocity,identity),
                       (n.end,'note off',n.pitch,0,identity)])
    events.extend((c.time,'control change',c.number,c.value,None)
                  for c in instrument.control_changes)
    events.extend((b.time,'pitch bend',b.pitch,0,None) for b in instrument.pitch_bends)
    events.sort(key=lambda e:(e[0],e[1]!='note off'))
    owners={}
    for time,kind,key,value,identity in events:
        if kind=='note on':
            owners[key]=identity
        elif kind=='note off':
            if owners.get(key)!=identity:
                kind='obsolete note off'
            else:
                del owners[key]
        yield time,kind,key,value


def _render_owned(instrument,synth,sfid,fs):
    synth.program_select(0,sfid,0,instrument.program)
    events=list(owned_note_events(instrument))
    if not events:return np.array([])
    current_time=events[0][0]
    deltas=[b[0]-a[0] for a,b in zip(events,events[1:])]+[1.]
    audio=np.zeros(int(np.ceil(fs*(current_time+sum(deltas)))))
    for (_,kind,key,value),delta in zip(events,deltas):
        if kind=='note on':synth.noteon(0,key,value)
        elif kind=='note off':synth.noteoff(0,key)
        elif kind=='control change':synth.cc(0,key,value)
        elif kind=='pitch bend':synth.pitch_bend(0,key)
        begin=int(fs*current_time);end=int(fs*(current_time+delta))
        audio[begin:end]+=synth.get_samples(end-begin)[::2]
        current_time+=delta
    return audio


def render_piano_safe(midi,soundfont,fs,piano_indices):
    """Use the original path unless a Piano instrument has a real collision."""
    affected={i for i in piano_indices if has_same_key_overlap(midi.instruments[i])}
    if not affected:
        return midi.fluidsynth(fs=fs,sf2_path=soundfont)
    synth,sfid,dispose=get_fluidsynth_instance(soundfont,0,fs)
    try:
        waves=[(_render_owned(t,synth,sfid,fs) if i in affected else
                t.fluidsynth(synthesizer=synth,sfid=sfid))
               for i,t in enumerate(midi.instruments)]
    finally:
        if dispose:synth.delete()
    audio=np.zeros(max((len(w) for w in waves),default=0))
    for w in waves:audio[:len(w)]+=w
    peak=np.max(np.abs(audio)) if len(audio) else 0
    if peak:audio/=peak
    return audio
