"""Local pitch evidence for a vocal lead rejected by whole-stem similarity."""
from copy import deepcopy


def supported_vocal_notes(notes, runs, spectral_scores=None):
    kept=[]
    for note in sorted(notes,key=lambda n:n.start):
        duration=note.end-note.start
        if duration<.055:continue
        intervals=sorted((max(note.start,r['start']),min(note.end,r['end']))
            for r in runs if r['confidence']>=.65 and r['pitch']==note.pitch
            and min(note.end,r['end'])>max(note.start,r['start']))
        coverage=0.;finish=note.start
        for start,end in intervals:
            coverage+=max(0.,end-max(start,finish));finish=max(finish,end)
        score=(spectral_scores or {}).get((note.pitch,note.start,note.end),0.)
        if coverage>=max(.035,.45*duration) or score>=.50:
            kept.append(deepcopy(note))
    # Isolated supported pitches are not enough to establish a melody.
    connected=[n for i,n in enumerate(kept) if any(
        abs(n.pitch-other.pitch)<=7 and -.025<=max(n.start,other.start)-min(n.end,other.end)<=.5
        for j,other in enumerate(kept) if i!=j)]
    return connected if len(connected)>=4 else []


def recover_locally_supported_vocal(source,midi_path):
    import librosa,numpy as np,pretty_midi
    audio,sr=librosa.load(source,sr=22050)
    f0,_,prob=librosa.pyin(audio,sr=sr,hop_length=256,
                         fmin=librosa.midi_to_hz(45),fmax=librosa.midi_to_hz(88))
    runs=[];i=0
    pitches=np.rint(librosa.hz_to_midi(np.where(np.isfinite(f0),f0,1))).astype(int)
    while i<len(f0):
        if not np.isfinite(f0[i]) or prob[i]<.5:
            i+=1;continue
        j=i+1
        while j<len(f0) and np.isfinite(f0[j]) and prob[j]>=.5 and pitches[j]==pitches[i]:j+=1
        if j-i>=3:
            runs.append({'start':i*256/sr,'end':j*256/sr,
                         'pitch':int(pitches[i]),'confidence':float(np.mean(prob[i:j]))})
        i=j
    midi=pretty_midi.PrettyMIDI(midi_path)
    original=[n for t in midi.instruments for n in t.notes]
    # Review spectral agreement locally rather than penalizing an entire
    # phrase for detector silence or leakage elsewhere in the stem.
    rendered=midi.synthesize(fs=sr)
    source_cqt=np.nan_to_num(abs(librosa.cqt(y=audio,sr=sr,hop_length=256)))
    rendered_cqt=np.nan_to_num(abs(librosa.cqt(y=rendered,sr=sr,hop_length=256)))
    length=max(source_cqt.shape[1],rendered_cqt.shape[1])
    source_cqt=np.pad(source_cqt,((0,0),(0,length-source_cqt.shape[1])))
    rendered_cqt=np.pad(rendered_cqt,((0,0),(0,length-rendered_cqt.shape[1])))
    norms=np.linalg.norm(source_cqt,axis=0)*np.linalg.norm(rendered_cqt,axis=0)
    similarity=np.divide(np.sum(source_cqt*rendered_cqt,axis=0),norms,
                         out=np.zeros(length),where=norms>1e-10)
    scores={}
    for note in original:
        begin=int(note.start*sr/256);end=min(length,int(note.end*sr/256))
        if end>begin:scores[(note.pitch,note.start,note.end)]=float(np.median(similarity[begin:end]))
    kept=supported_vocal_notes(original,runs,scores)
    if kept:
        track=pretty_midi.Instrument(0,name='Locally supported vocal melody')
        track.notes=kept;midi.instruments=[track];midi.write(midi_path)
    return {'accepted':bool(kept),'candidate_notes':len(original),'supported_notes':len(kept),
            'policy':'local_pitch_or_spectral_evidence_with_phrase_neighbors',
            'reason':'Local vocal pitch evidence, not whole-stem spectral similarity'}
