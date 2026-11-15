"""Room-tone fades and intro routing. Every file stays inside pytest's tmp_path."""

from __future__ import annotations

import math
from pathlib import Path

import numpy as np

from podcast_stripper.cleanup import (
    intro_route_mask,
    mix_speaker_waves,
    parse_intro_end,
    parse_room_tone,
    shared_speaker_gates,
)
from podcast_stripper.export import export_speaker_tracks, load_wav, save_wav


def _sine(frequency: float, seconds: float, sample_rate: int, amplitude: float = 0.3) -> np.ndarray:
    times = np.arange(int(seconds * sample_rate), dtype=np.float64) / sample_rate
    samples = (amplitude * np.sin(2 * math.pi * frequency * times) * 32767).astype(np.int16)
    return samples.reshape(-1, 1)


def _noise(seconds: float, sample_rate: int, amplitude: float, seed: int = 1) -> np.ndarray:
    count = int(seconds * sample_rate)
    rng = np.random.RandomState(seed)
    samples = np.clip(rng.randn(count) * amplitude * 32767, -32767, 32767).astype(np.int16)
    return samples.reshape(-1, 1)


def _db(audio: np.ndarray) -> float:
    values = audio.astype(np.float64)
    rms = float(np.sqrt(np.mean(values**2))) if values.size else 0.0
    if rms < 1e-6:
        return -120.0
    return float(20.0 * math.log10(rms))


def test_parse_room_tone_and_intro_clock():
    assert parse_room_tone("natural") == 0.0
    assert parse_room_tone("off") is None
    assert parse_room_tone("-20") == -20.0
    assert parse_room_tone(None) == 0.0
    assert parse_intro_end(None) is None
    assert parse_intro_end("") is None
    assert parse_intro_end("1:05") == 65.0
    assert parse_intro_end("90") == 90.0
    try:
        parse_intro_end("1:60")
        raise AssertionError("expected ValueError")
    except ValueError:
        pass


def test_natural_room_matches_the_pause_and_off_is_silent():
    sample_rate = 16000
    speech = _sine(220, 0.5, sample_rate, amplitude=0.45)
    room = _noise(1.4, sample_rate, amplitude=0.02, seed=3)
    vocal = np.concatenate([speech, room], axis=0)
    length = vocal.shape[0]
    gate = np.zeros(length, dtype=np.float64)
    gate[: speech.shape[0]] = 1.0

    natural = mix_speaker_waves(vocal, [gate], sample_rate, room_db=0.0)[0]
    off = mix_speaker_waves(vocal, [gate], sample_rate, room_db=None)[0]
    quieter = mix_speaker_waves(vocal, [gate], sample_rate, room_db=-20.0)[0]

    words = slice(sample_rate // 10, speech.shape[0] - sample_rate // 10)
    pause = slice(speech.shape[0] + int(0.4 * sample_rate), speech.shape[0] + int(1.1 * sample_rate))
    assert abs(_db(natural[words]) - _db(vocal[words])) < 1.0
    assert abs(_db(natural[pause]) - _db(vocal[pause])) < 1.0
    assert _db(off[pause]) < -80.0
    assert abs(_db(quieter[pause]) - (_db(vocal[pause]) - 20.0)) < 1.5

    # The -20 dB bed reaches the pause on a ramp, not a one-sample cut.
    fade = int(sample_rate * 165 / 1000)
    mid_fade = slice(speech.shape[0] + fade // 2 - 40, speech.shape[0] + fade // 2 + 40)
    assert _db(quieter[mid_fade]) > _db(quieter[pause]) + 6.0
    assert _db(quieter[mid_fade]) < _db(vocal[words]) - 6.0

    # Natural does not fall to a hole at the same spot. Off does.
    assert _db(natural[pause]) > _db(off[pause]) + 30.0
    drop_natural = _db(natural[words]) - _db(natural[pause])
    drop_stem = _db(vocal[words]) - _db(vocal[pause])
    assert abs(drop_natural - drop_stem) < 2.0


def test_room_stays_off_while_the_other_person_talks():
    sample_rate = 16000
    length = sample_rate * 2
    vocal = _sine(330, 2.0, sample_rate, amplitude=0.3)
    gates = shared_speaker_gates(
        length,
        sample_rate,
        [[(0.0, 0.7)], [(1.1, 2.0)]],
        hold_ms=0,
        fade_ms=12,
    )
    tracks = mix_speaker_waves(vocal, gates, sample_rate, room_db=0.0)
    other_words = slice(int(1.4 * sample_rate), int(1.8 * sample_rate))
    assert _db(tracks[0][other_words]) < _db(vocal[other_words]) - 20.0
    assert _db(tracks[1][other_words]) > _db(vocal[other_words]) - 2.0
    # The interior of a solo turn stays at full level (the fade does not dig in).
    solo = slice(int(0.2 * sample_rate), int(0.45 * sample_rate))
    assert abs(_db(tracks[0][solo]) - _db(vocal[solo])) < 1.0


def test_intro_voice_over_music_moves_to_music_and_sums(tmp_path: Path):
    sample_rate = 8000
    mixed = _sine(180, 2.0, sample_rate, amplitude=0.22)
    voice = _sine(520, 2.0, sample_rate, amplitude=0.22)
    intro_vocal = np.clip(mixed.astype(np.int32) + voice.astype(np.int32), -32767, 32767).astype(np.int16)
    intro_music = mixed
    dry_a = _sine(300, 4.2, sample_rate, amplitude=0.35)
    dry_b = _sine(420, 4.2, sample_rate, amplitude=0.35)
    bleed = _sine(90, 8.4, sample_rate, amplitude=0.01)
    vocal = np.concatenate([intro_vocal, dry_a, dry_b], axis=0)
    music = np.concatenate([intro_music, bleed], axis=0)
    original = np.clip(vocal.astype(np.int32) + music.astype(np.int32), -32767, 32767).astype(np.int16)
    segments = [
        (0.2, 1.7, "SPEAKER_00"),
        (2.2, 6.0, "SPEAKER_00"),
        (6.2, 10.2, "SPEAKER_01"),
    ]
    source = tmp_path / "mix.wav"
    voice_wav = tmp_path / "vocals.wav"
    music_wav = tmp_path / "music.wav"
    save_wav(source, original, sample_rate)
    save_wav(voice_wav, vocal, sample_rate)
    save_wav(music_wav, music, sample_rate)
    output = tmp_path / "out"
    manifest = export_speaker_tracks(
        source,
        output,
        segments,
        work_wav=source,
        voice_wav=voice_wav,
        music_wav=music_wav,
        room_tone=None,
    )
    assert manifest["intro"]["method"].startswith("dry-speech")
    assert 1.5 <= manifest["intro"]["auto_end"] <= 2.6

    speaker_a, _ = load_wav(output / "Speaker_1.wav")
    speaker_b, _ = load_wav(output / "Speaker_2.wav")
    music_track, _ = load_wav(output / "Music_and_SFX.wav")
    intro = slice(int(0.4 * sample_rate), int(1.4 * sample_rate))
    assert _db(speaker_a[intro]) < -60.0
    assert _db(speaker_b[intro]) < -60.0
    assert abs(_db(music_track[intro]) - _db(original[intro])) < 1.0
    summed = speaker_a[intro].astype(np.float64) + speaker_b[intro].astype(np.float64) + music_track[intro].astype(np.float64)
    assert abs(_db(summed) - _db(original[intro])) < 1.0

    talk = slice(int(3.0 * sample_rate), int(5.0 * sample_rate))
    assert _db(speaker_a[talk]) > -25.0
    assert _db(speaker_b[talk]) < _db(speaker_a[talk]) - 20.0
    # The dry conversation was not moved onto the music track.
    assert _db(music_track[talk]) < _db(original[talk]) - 12.0


def test_quiet_bed_under_conversation_stays_on_speakers(tmp_path: Path):
    sample_rate = 8000
    seconds = 10.0
    vocal = _sine(280, seconds, sample_rate, amplitude=0.32)
    bed = _sine(80, seconds, sample_rate, amplitude=0.03)
    original = np.clip(vocal.astype(np.int32) + bed.astype(np.int32), -32767, 32767).astype(np.int16)
    segments = [(0.2, 4.8, "SPEAKER_00"), (5.0, 9.6, "SPEAKER_01")]
    source = tmp_path / "mix.wav"
    save_wav(source, original, sample_rate)
    save_wav(tmp_path / "vocals.wav", vocal, sample_rate)
    save_wav(tmp_path / "music.wav", bed, sample_rate)
    output = tmp_path / "out"
    manifest = export_speaker_tracks(
        source,
        output,
        segments,
        work_wav=source,
        voice_wav=tmp_path / "vocals.wav",
        music_wav=tmp_path / "music.wav",
        room_tone=None,
    )
    assert manifest["intro"]["coverage"] < 0.05
    speaker, _ = load_wav(output / "Speaker_1.wav")
    talk = slice(int(1.0 * sample_rate), int(3.0 * sample_rate))
    assert _db(speaker[talk]) > -20.0


def test_loud_bed_under_two_people_is_not_stolen(tmp_path: Path):
    sample_rate = 8000
    vocal = _sine(300, 10.0, sample_rate, amplitude=0.28)
    bed = _sine(70, 10.0, sample_rate, amplitude=0.24)
    original = np.clip(vocal.astype(np.int32) + bed.astype(np.int32), -32767, 32767).astype(np.int16)
    segments = [(0.3, 4.8, "SPEAKER_00"), (5.1, 9.5, "SPEAKER_01")]
    mask, info = intro_route_mask(
        vocal.shape[0],
        sample_rate,
        segments,
        bed,
        vocal,
        detect=True,
    )
    assert info["auto_end"] is None
    assert float(np.mean(mask > 0.5)) < 0.05
    source = tmp_path / "mix.wav"
    save_wav(source, original, sample_rate)
    save_wav(tmp_path / "vocals.wav", vocal, sample_rate)
    save_wav(tmp_path / "music.wav", bed, sample_rate)
    output = tmp_path / "out"
    export_speaker_tracks(
        source,
        output,
        segments,
        work_wav=source,
        voice_wav=tmp_path / "vocals.wav",
        music_wav=tmp_path / "music.wav",
        room_tone=None,
    )
    speaker, _ = load_wav(output / "Speaker_1.wav")
    talk = slice(int(1.0 * sample_rate), int(3.5 * sample_rate))
    assert _db(speaker[talk]) > -22.0


def test_manual_intro_end_overrides_a_dry_start(tmp_path: Path):
    sample_rate = 8000
    vocal = _sine(260, 6.0, sample_rate, amplitude=0.3)
    bleed = _sine(90, 6.0, sample_rate, amplitude=0.01)
    original = np.clip(vocal.astype(np.int32) + bleed.astype(np.int32), -32767, 32767).astype(np.int16)
    segments = [(0.0, 3.0, "SPEAKER_00"), (3.0, 6.0, "SPEAKER_01")]
    source = tmp_path / "mix.wav"
    save_wav(source, original, sample_rate)
    save_wav(tmp_path / "vocals.wav", vocal, sample_rate)
    save_wav(tmp_path / "music.wav", bleed, sample_rate)
    output = tmp_path / "out"
    manifest = export_speaker_tracks(
        source,
        output,
        segments,
        work_wav=source,
        voice_wav=tmp_path / "vocals.wav",
        music_wav=tmp_path / "music.wav",
        room_tone=None,
        intro_end=1.5,
    )
    assert manifest["intro"]["method"].startswith("manual")
    speaker, _ = load_wav(output / "Speaker_1.wav")
    music, _ = load_wav(output / "Music_and_SFX.wav")
    early = slice(int(0.2 * sample_rate), int(1.2 * sample_rate))
    later = slice(int(2.0 * sample_rate), int(2.8 * sample_rate))
    assert _db(speaker[early]) < -50.0
    assert abs(_db(music[early]) - _db(original[early])) < 1.5
    assert _db(speaker[later]) > -20.0


def test_export_room_tone_on_and_off(tmp_path: Path):
    sample_rate = 16000
    speech_a = _sine(240, 0.45, sample_rate, amplitude=0.4)
    pause = _noise(1.3, sample_rate, amplitude=0.025, seed=9)
    speech_b = _sine(360, 0.45, sample_rate, amplitude=0.4)
    vocal = np.concatenate([speech_a, pause, speech_b], axis=0)
    quiet_music = np.zeros_like(vocal)
    original = vocal.copy()
    segments = [(0.0, 0.45, "SPEAKER_00"), (1.75, 2.2, "SPEAKER_01")]
    source = tmp_path / "mix.wav"
    save_wav(source, original, sample_rate)
    save_wav(tmp_path / "vocals.wav", vocal, sample_rate)
    save_wav(tmp_path / "music.wav", quiet_music, sample_rate)

    def render(room, dest: Path):
        export_speaker_tracks(
            source,
            dest,
            segments,
            work_wav=source,
            voice_wav=tmp_path / "vocals.wav",
            music_wav=tmp_path / "music.wav",
            room_tone=room,
            detect_intro=False,
        )

    natural_dir = tmp_path / "natural"
    off_dir = tmp_path / "off"
    render(0.0, natural_dir)
    render(None, off_dir)
    pause_slice = slice(int(0.9 * sample_rate), int(1.4 * sample_rate))
    words = slice(int(0.1 * sample_rate), int(0.35 * sample_rate))
    natural, _ = load_wav(natural_dir / "Speaker_1.wav")
    off, _ = load_wav(off_dir / "Speaker_1.wav")
    other, _ = load_wav(natural_dir / "Speaker_2.wav")
    assert abs(_db(natural[pause_slice]) - _db(vocal[pause_slice])) < 2.0
    assert abs(_db(other[pause_slice]) - _db(vocal[pause_slice])) < 2.0
    assert _db(off[pause_slice]) < -70.0
    assert abs(_db(natural[words]) - _db(off[words])) < 1.5
    # The other person's words do not become this track's room.
    their_words = slice(int(1.9 * sample_rate), int(2.1 * sample_rate))
    assert _db(natural[their_words]) < _db(vocal[their_words]) - 18.0


def test_spikes_between_solo_speech_do_not_steal_the_sentence(tmp_path: Path):
    """Two loud music-stem spikes must not pull the words between them onto Music/SFX."""
    sample_rate = 8000
    seconds = 10.0
    vocal = _sine(300, seconds, sample_rate, amplitude=0.32)
    other = _sine(90, seconds, sample_rate, amplitude=0.01)
    for start in (3.0, 5.2):
        i0 = int(start * sample_rate)
        i1 = int((start + 0.25) * sample_rate)
        other[i0:i1] = _sine(70, 0.25, sample_rate, amplitude=0.55)
    original = np.clip(vocal.astype(np.int32) + other.astype(np.int32), -32767, 32767).astype(np.int16)
    segments = [(0.2, 9.6, "SPEAKER_00")]
    mask, _info = intro_route_mask(
        vocal.shape[0],
        sample_rate,
        segments,
        other,
        vocal,
        detect=True,
    )
    between = slice(int(3.5 * sample_rate), int(5.0 * sample_rate))
    assert float(np.mean(mask[between] > 0.5)) < 0.05

    source = tmp_path / "mix.wav"
    save_wav(source, original, sample_rate)
    save_wav(tmp_path / "vocals.wav", vocal, sample_rate)
    save_wav(tmp_path / "music.wav", other, sample_rate)
    output = tmp_path / "out"
    export_speaker_tracks(
        source,
        output,
        segments,
        work_wav=source,
        voice_wav=tmp_path / "vocals.wav",
        music_wav=tmp_path / "music.wav",
        room_tone=None,
    )
    speaker, _ = load_wav(output / "Speaker_1.wav")
    music, _ = load_wav(output / "Music_and_SFX.wav")
    assert _db(speaker[between]) > -22.0
    assert _db(music[between]) < _db(original[between]) - 12.0


def test_solo_voice_over_a_later_music_hit_stays_on_music(tmp_path: Path):
    sample_rate = 8000
    dry = _sine(280, 9.0, sample_rate, amplitude=0.34)
    dry_bed = _sine(90, 9.0, sample_rate, amplitude=0.008)
    hit_voice = _sine(360, 3.5, sample_rate, amplitude=0.22)
    hit_music = _sine(80, 3.5, sample_rate, amplitude=0.30)
    tail = _sine(280, 3.0, sample_rate, amplitude=0.34)
    tail_bed = _sine(90, 3.0, sample_rate, amplitude=0.008)
    vocal = np.concatenate([dry, hit_voice, tail], axis=0)
    music_stem = np.concatenate([dry_bed, hit_music, tail_bed], axis=0)
    original = np.clip(vocal.astype(np.int32) + music_stem.astype(np.int32), -32767, 32767).astype(np.int16)
    segments = [(0.0, 15.5, "SPEAKER_00")]
    mask, info = intro_route_mask(
        vocal.shape[0],
        sample_rate,
        segments,
        music_stem,
        vocal,
        detect=True,
    )
    assert info["auto_end"] is None or float(info["auto_end"]) < 0.75
    hit = slice(int(10.0 * sample_rate), int(12.0 * sample_rate))
    earlier = slice(int(2.0 * sample_rate), int(6.0 * sample_rate))
    assert float(np.mean(mask[hit] > 0.5)) > 0.8
    assert float(np.mean(mask[earlier] > 0.5)) < 0.05

    source = tmp_path / "mix.wav"
    save_wav(source, original, sample_rate)
    save_wav(tmp_path / "vocals.wav", vocal, sample_rate)
    save_wav(tmp_path / "music.wav", music_stem, sample_rate)
    output = tmp_path / "out"
    export_speaker_tracks(
        source,
        output,
        segments,
        work_wav=source,
        voice_wav=tmp_path / "vocals.wav",
        music_wav=tmp_path / "music.wav",
        room_tone=None,
    )
    speaker, _ = load_wav(output / "Speaker_1.wav")
    music, _ = load_wav(output / "Music_and_SFX.wav")
    assert _db(speaker[hit]) < -45.0
    assert abs(_db(music[hit]) - _db(original[hit])) < 1.5
    summed = speaker[hit].astype(np.float64) + music[hit].astype(np.float64)
    assert abs(_db(summed) - _db(original[hit])) < 1.5
    assert _db(speaker[earlier]) > -20.0


def test_quiet_pause_is_not_sent_to_music(tmp_path: Path):
    sample_rate = 8000
    speech = _sine(260, 9.0, sample_rate, amplitude=0.32)
    bleed = _sine(100, 9.0, sample_rate, amplitude=0.01)
    pause_voice = _noise(2.2, sample_rate, amplitude=0.001, seed=4)
    pause_bed = _noise(2.2, sample_rate, amplitude=0.001, seed=5)
    vocal = np.concatenate([speech, pause_voice], axis=0)
    music_stem = np.concatenate([bleed, pause_bed], axis=0)
    original = np.clip(vocal.astype(np.int32) + music_stem.astype(np.int32), -32767, 32767).astype(np.int16)
    segments = [(0.1, 8.8, "SPEAKER_00")]
    mask, _info = intro_route_mask(
        vocal.shape[0],
        sample_rate,
        segments,
        music_stem,
        vocal,
        detect=True,
    )
    pause = slice(int(9.3 * sample_rate), int(10.8 * sample_rate))
    assert float(np.mean(mask[pause] > 0.5)) < 0.05

    source = tmp_path / "mix.wav"
    save_wav(source, original, sample_rate)
    save_wav(tmp_path / "vocals.wav", vocal, sample_rate)
    save_wav(tmp_path / "music.wav", music_stem, sample_rate)
    output = tmp_path / "out"
    export_speaker_tracks(
        source,
        output,
        segments,
        work_wav=source,
        voice_wav=tmp_path / "vocals.wav",
        music_wav=tmp_path / "music.wav",
        room_tone=0.0,
    )
    speaker, _ = load_wav(output / "Speaker_1.wav")
    # The pause keeps the vocal stem's room instead of being muted for Music/SFX.
    assert _db(speaker[pause]) > _db(vocal[pause]) - 3.0
