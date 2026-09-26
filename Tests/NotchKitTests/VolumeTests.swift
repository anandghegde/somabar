import Testing
@testable import NotchKit

@Suite struct VolumeTests {
    @Test func keysDecodeFromData1() {
        let upDown = VolumeKey.decode(data1: (0 << 16) | (0xA << 8))
        #expect(upDown?.key == .up)
        #expect(upDown?.isDown == true)
        #expect(upDown?.isRepeat == false)
        let downRepeat = VolumeKey.decode(data1: (1 << 16) | (0xA << 8) | 1)
        #expect(downRepeat?.key == .down)
        #expect(downRepeat?.isRepeat == true)
        let muteUp = VolumeKey.decode(data1: (7 << 16) | (0xB << 8))
        #expect(muteUp?.key == .mute)
        #expect(muteUp?.isDown == false)
        // Play/pause (16) and brightness (2) are left alone.
        #expect(VolumeKey.decode(data1: (16 << 16) | (0xA << 8)) == nil)
        #expect(VolumeKey.decode(data1: (2 << 16) | (0xA << 8)) == nil)
    }

    @Test func stepsFollowTheSixteenthsGrid() {
        #expect(VolumeStep.next(from: 0.5, up: true, fine: false) == 0.5625)
        #expect(VolumeStep.next(from: 0.5, up: false, fine: false) == 0.4375)
        // Between two steps: to the next one in the key's direction.
        #expect(VolumeStep.next(from: 0.52, up: true, fine: false) == 0.5625)
        #expect(VolumeStep.next(from: 0.52, up: false, fine: false) == 0.5)
        // Float noise just under a step still counts as that step.
        #expect(VolumeStep.next(from: 0.37499994, up: true, fine: false) == 0.4375)
    }

    @Test func fineStepsAreSixtyFourths() {
        #expect(VolumeStep.next(from: 0.5, up: true, fine: true) == 0.515625)
        #expect(VolumeStep.next(from: 0.5, up: false, fine: true) == 0.484375)
    }

    @Test func stepsClamp() {
        #expect(VolumeStep.next(from: 1, up: true, fine: false) == 1)
        #expect(VolumeStep.next(from: 0.98, up: true, fine: false) == 1)
        #expect(VolumeStep.next(from: 0, up: false, fine: false) == 0)
        #expect(VolumeStep.next(from: 0.01, up: false, fine: true) == 0)
        #expect(VolumeStep.next(from: 1.5, up: false, fine: false) == 0.9375)
    }

    @Test func words() {
        #expect(VolumeText.percent(0.5625) == "56 %")
        #expect(VolumeText.percent(1) == "100 %")
        #expect(VolumeText.pulse(level: 0.5, muted: true) == "Muted")
        #expect(VolumeText.accessibilityLabel(level: 0.25, muted: false) == "Volume 25 %")
        #expect(VolumeText.symbol(level: 0.5, muted: true) == "speaker.slash.fill")
        #expect(VolumeText.symbol(level: 0, muted: false) == "speaker.slash.fill")
        #expect(VolumeText.symbol(level: 0.2, muted: false) == "speaker.wave.1.fill")
        #expect(VolumeText.symbol(level: 0.5, muted: false) == "speaker.wave.2.fill")
        #expect(VolumeText.symbol(level: 0.9, muted: false) == "speaker.wave.3.fill")
    }
}
