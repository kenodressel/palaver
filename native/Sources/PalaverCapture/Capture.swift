// Audio capture (phase 2, Tasks 5 to 7).
// - Task 5: PCM decoding, resampling, alignment and the `.part` writer
//   (PCM.swift, Resampler.swift, Aligner.swift, TrackWriter.swift).
// - Task 6: the sources and the recorder (ProcessTap.swift, AVMic.swift,
//   SCStreamSource.swift, SampleBuffers.swift, CaptureRing.swift, CaptureRecorder.swift).
import PalaverCore

public enum PalaverCapture {}
