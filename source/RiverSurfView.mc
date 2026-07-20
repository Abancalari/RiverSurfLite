import Toybox.WatchUi;
import Toybox.Graphics;
import Toybox.Activity;
import Toybox.FitContributor;
import Toybox.Math;

class RiverSurfView extends WatchUi.DataField {

    // FIT Contributor Fields
    private var mWaveCountField = null;
    private var mTimeSurfingField = null;
    private var mWaveDurationField = null;

    // Surfing states
    enum SurfState {
        STATE_WAITING = 0,
        STATE_SURFING = 1,
        STATE_SWEPT = 2
    }

    private var mState = STATE_WAITING;

    // Wave statistics
    private var mTotalWaves = 0;
    private var mTotalSurfingTime = 0;
    private var mCurrentWaveDuration = 0;
    private var mWaveRegistered = false;

    // Current motion cadence & speed metrics
    private var mCadence = 0;
    private var mSpeed = 0.0;

    // Motion Cadence Threshold for DataFields (cycles/min)
    private const SURF_CADENCE_THRESHOLD = 15;
    private const SWEEP_SPEED_THRESHOLD = 2.5; // 2.5 m/s = 9 km/h

    function initialize() {
        DataField.initialize();

        try {
            mWaveCountField = createField(
                "wave_count",
                0,
                FitContributor.DATA_TYPE_UINT16,
                { :mesgType => FitContributor.MESG_TYPE_SESSION, :label => "Waves" }
            );
            mTimeSurfingField = createField(
                "time_surfing",
                1,
                FitContributor.DATA_TYPE_UINT32,
                { :mesgType => FitContributor.MESG_TYPE_SESSION, :label => "Time Surfing", :units => "s" }
            );
            mWaveDurationField = createField(
                "wave_duration",
                2,
                FitContributor.DATA_TYPE_UINT16,
                { :mesgType => FitContributor.MESG_TYPE_RECORD, :label => "Wave Duration", :units => "s" }
            );
        } catch (e) {
            // FIT field fallback
        }
    }

    function compute(info) {
        try {
            mSpeed = 0.0;
            mCadence = 0;

            if (info != null) {
                if (info.currentSpeed != null) {
                    mSpeed = info.currentSpeed;
                }
                if (info.currentCadence != null) {
                    mCadence = info.currentCadence;
                }
            }

            switch (mState) {
                case STATE_WAITING:
                    if (mCadence > SURF_CADENCE_THRESHOLD && mSpeed < SWEEP_SPEED_THRESHOLD) {
                        mState = STATE_SURFING;
                        mCurrentWaveDuration = 0;
                        mWaveRegistered = false;
                    }
                    break;

                case STATE_SURFING:
                    mCurrentWaveDuration += 1;

                    if (mCurrentWaveDuration >= 3 && !mWaveRegistered) {
                        mTotalWaves += 1;
                        mWaveRegistered = true;
                        if (mWaveCountField != null) {
                            mWaveCountField.setData(mTotalWaves);
                        }
                    }

                    if (mWaveRegistered) {
                        mTotalSurfingTime += 1;
                        if (mTimeSurfingField != null) {
                            mTimeSurfingField.setData(mTotalSurfingTime);
                        }
                    }

                    if (mWaveDurationField != null) {
                        mWaveDurationField.setData(mCurrentWaveDuration);
                    }

                    if (mSpeed >= SWEEP_SPEED_THRESHOLD) {
                        mState = STATE_SWEPT;
                        if (mWaveDurationField != null) {
                            mWaveDurationField.setData(0);
                        }
                    } else if (mCadence <= SURF_CADENCE_THRESHOLD) {
                        mState = STATE_WAITING;
                        if (mWaveDurationField != null) {
                            mWaveDurationField.setData(0);
                        }
                    }
                    break;

                case STATE_SWEPT:
                    if (mSpeed < SWEEP_SPEED_THRESHOLD) {
                        mState = STATE_WAITING;
                    }
                    break;
            }
        } catch (e) {
            // Keep state intact
        }

        return null;
    }

    function onUpdate(dc) {
        try {
            var rawBg = getBackgroundColor();
            var isDark = (rawBg != null && (rawBg == Graphics.COLOR_BLACK || rawBg == Graphics.COLOR_DK_GRAY));

            var bgColor = isDark ? Graphics.COLOR_BLACK : Graphics.COLOR_WHITE;
            var textColor = isDark ? Graphics.COLOR_WHITE : Graphics.COLOR_BLACK;

            dc.setColor(bgColor, bgColor);
            dc.clear();

            var width = dc.getWidth();
            var height = dc.getHeight();

            dc.setColor(textColor, Graphics.COLOR_TRANSPARENT);
            dc.drawRectangle(1, 1, width - 2, height - 2);

            var statusText = "[ WAITING ]";
            if (mState == STATE_SURFING) {
                statusText = "SURFING!";
            } else if (mState == STATE_SWEPT) {
                statusText = "! SWEPT !";
            }

            var font = Graphics.FONT_MEDIUM;
            if (height < 50) {
                font = Graphics.FONT_SMALL;
            } else if (height > 90) {
                font = Graphics.FONT_LARGE;
            }

            if (mState == STATE_SURFING) {
                var bannerW = width - 12;
                var bannerH = (font == Graphics.FONT_LARGE) ? 36 : 26;
                var bannerX = 6;
                var bannerY = (height / 2) - (bannerH / 2) - 8;

                dc.setColor(textColor, Graphics.COLOR_TRANSPARENT);
                dc.fillRectangle(bannerX, bannerY, bannerW, bannerH);
                dc.setColor(bgColor, Graphics.COLOR_TRANSPARENT);
            }

            dc.drawText(
                width / 2,
                (height / 2) - 8,
                font,
                statusText,
                Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
            );

            // Diagnostics & Waves info text
            dc.setColor(textColor, Graphics.COLOR_TRANSPARENT);
            var debugText = "CAD:" + mCadence.toString() + " | WAVES:" + mTotalWaves.toString();
            
            if (height >= 50) {
                dc.drawText(
                    width / 2,
                    height - 24,
                    Graphics.FONT_XTINY,
                    debugText,
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
                );
            }
        } catch (e) {
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_WHITE);
            dc.clear();
            dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
            dc.drawText(
                dc.getWidth() / 2,
                dc.getHeight() / 2,
                Graphics.FONT_SMALL,
                "WAITING",
                Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
            );
        }
    }
}
