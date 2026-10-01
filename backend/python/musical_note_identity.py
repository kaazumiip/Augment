"""Experimental, source-evidence-based musical continuation decision.

This answers whether adjacent score events represent one musical note. It does
not decide how a particular instrument sustains that note.
"""


def classify_continuation(*, same_pitch, gap_seconds, inter_onset_seconds,
                          prior_duration_seconds, onset_ratio,
                          rms_trough_ratio, strong_beat=False,
                          physical_continuity=True, same_phrase=True):
    if not same_pitch:
        return False, 'different pitch'
    if not physical_continuity:
        return False, 'physical voice cannot continue'
    if gap_seconds > .025:
        return False, 'audible or notated rest'
    if not same_phrase:
        return False, 'phrase boundary'
    if strong_beat:
        return False, 'beat may require re-articulation'
    if prior_duration_seconds < .14 or inter_onset_seconds > .24:
        return False, 'duration or inter-onset interval supports re-attack'
    if onset_ratio >= 1.35 or rms_trough_ratio <= .65:
        return False, 'source onset or energy break supports re-attack'
    return True, 'contiguous physical voice with no clear new source onset'
