import Toybox.WatchUi;
import Toybox.Graphics;
import Toybox.Activity;
import Toybox.FitContributor;
import Toybox.Sensor;
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

    // Rolling buffer for accelerometer magnitude (5 seconds)
    private const BUFFER_SIZE = 5;
    private var mAccelBuffer = [1000.0, 1000.0, 1000.0, 1000.0, 1000.0];
    private var mBufferIndex = 0;
    private var mLastAccelMag = 1000.0;

    // Responsive threshold for motion variance (5000 millig^2)
    private const SURF_ACCEL_VAR_THRESHOLD = 5000.0;
    private const SWEEP_SPEED_THRESHOLD = 2.5;

    function initialize() {
        DataField.initialize();

        // Custom FIT Field IDs: Count (0, SESSION), Time (1, SESSION), Duration (2, RECORD)
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
            // Safe fallback if FIT fields initialization encounters device limits
        }
    }

    function compute(info) {
        try {
            var speed = (info != null && info.currentSpeed != null) ? info.currentSpeed : 0.0;

            // Safe DataField sensor query using Sensor.getInfo()
            var accelMag = mLastAccelMag;
            var sensorInfo = Sensor.getInfo();
            if (sensorInfo != null && sensorInfo.accel != null) {
                var accel = sensorInfo.accel;
                if (accel != null && accel.size() >= 3) {
                    var ax = accel[0].toFloat();
                    var ay = accel[1].toFloat();
                    var az = accel[2].toFloat();
                    accelMag = Math.sqrt(ax * ax + ay * ay + az * az);
                    mLastAccelMag = accelMag;
                }
            }

            mAccelBuffer[mBufferIndex] = accelMag;
            mBufferIndex = (mBufferIndex + 1) % BUFFER_SIZE;

            var mean = 0.0;
            for (var i = 0; i < BUFFER_SIZE; i++) {
                mean += mAccelBuffer[i];
            }
            mean = mean / BUFFER_SIZE;

            var variance = 0.0;
            for (var i = 0; i < BUFFER_SIZE; i++) {
                var diff = mAccelBuffer[i] - mean;
                variance += diff * diff;
            }
            variance = variance / BUFFER_SIZE;

            switch (mState) {
                case STATE_WAITING:
                    if (variance > SURF_ACCEL_VAR_THRESHOLD && speed < SWEEP_SPEED_THRESHOLD) {
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

                    if (speed >= SWEEP_SPEED_THRESHOLD) {
                        mState = STATE_SWEPT;
                        if (mWaveDurationField != null) {
                            mWaveDurationField.setData(0);
                        }
                    } else if (variance <= SURF_ACCEL_VAR_THRESHOLD) {
                        mState = STATE_WAITING;
                        if (mWaveDurationField != null) {
                            mWaveDurationField.setData(0);
                        }
                    }
                    break;

                case STATE_SWEPT:
                    if (speed < SWEEP_SPEED_THRESHOLD) {
                        mState = STATE_WAITING;
                    }
                    break;
            }
        } catch (e) {
            // Keep state intact on exception
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

            // Draw outer border box
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

            // Inverted highlight banner for SURFING state
            if (mState == STATE_SURFING) {
                var bannerW = width - 12;
                var bannerH = (font == Graphics.FONT_LARGE) ? 36 : 26;
                var bannerX = 6;
                var bannerY = (height / 2) - (bannerH / 2) - 4;

                dc.setColor(textColor, Graphics.COLOR_TRANSPARENT);
                dc.fillRectangle(bannerX, bannerY, bannerW, bannerH);
                dc.setColor(bgColor, Graphics.COLOR_TRANSPARENT);
            }

            // Draw status string
            dc.drawText(
                width / 2,
                (height / 2) - 4,
                font,
                statusText,
                Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
            );

            // Draw wave count sub-label
            dc.setColor(textColor, Graphics.COLOR_TRANSPARENT);
            var subText = "WAVES: " + mTotalWaves.toString();
            if (height >= 60) {
                dc.drawText(
                    width / 2,
                    height - 12,
                    Graphics.FONT_XTINY,
                    subText,
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
                );
            }
        } catch (e) {
            // Fallback rendering on error
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
