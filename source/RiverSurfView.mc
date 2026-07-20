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
    private var mCurrentVariance = 0.0;
    private var mHasAccelData = false;

    // Motion variance threshold (millig^2)
    private const SURF_ACCEL_VAR_THRESHOLD = 2000.0;
    private const SWEEP_SPEED_THRESHOLD = 2.5;

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

        // Register accelerometer listener to activate hardware sensor stream
        try {
            Sensor.registerSensorDataListener(method(:onAccelData), {
                :period => 1,
                :accelerometer => { :enabled => true }
            });
        } catch (e) {
            // Fallback for devices without sensor listener
        }
    }

    // Callback received when accelerometer sample batch is ready
    function onAccelData(sensorData as Sensor.SensorData) as Void {
        if (sensorData != null && sensorData.accelerometerData != null) {
            var x = sensorData.accelerometerData.x;
            var y = sensorData.accelerometerData.y;
            var z = sensorData.accelerometerData.z;
            if (x != null && y != null && z != null && x.size() > 0) {
                var maxMag = 0.0;
                for (var i = 0; i < x.size(); i++) {
                    var ax = x[i].toFloat();
                    var ay = y[i].toFloat();
                    var az = z[i].toFloat();
                    var mag = Math.sqrt(ax * ax + ay * ay + az * az);
                    if (mag > maxMag) {
                        maxMag = mag;
                    }
                }
                mLastAccelMag = maxMag;
                mHasAccelData = true;
            }
        }
    }

    function compute(info) {
        try {
            var speed = 0.0;
            if (info != null && info.currentSpeed != null) {
                speed = info.currentSpeed;
            }

            // Also check Sensor.getInfo().accel as secondary source
            var accelMag = mLastAccelMag;
            var sensorInfo = Sensor.getInfo();
            if (sensorInfo != null && sensorInfo.accel != null) {
                var accel = sensorInfo.accel;
                if (accel != null && accel.size() >= 3) {
                    mHasAccelData = true;
                    var ax = accel[0].toFloat();
                    var ay = accel[1].toFloat();
                    var az = accel[2].toFloat();
                    var mag = Math.sqrt(ax * ax + ay * ay + az * az);
                    if (mag > accelMag) {
                        accelMag = mag;
                    }
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
            mCurrentVariance = variance / BUFFER_SIZE;

            switch (mState) {
                case STATE_WAITING:
                    if (mCurrentVariance > SURF_ACCEL_VAR_THRESHOLD && speed < SWEEP_SPEED_THRESHOLD) {
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
                    } else if (mCurrentVariance <= SURF_ACCEL_VAR_THRESHOLD) {
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
                var bannerY = (height / 2) - (bannerH / 2) - 4;

                dc.setColor(textColor, Graphics.COLOR_TRANSPARENT);
                dc.fillRectangle(bannerX, bannerY, bannerW, bannerH);
                dc.setColor(bgColor, Graphics.COLOR_TRANSPARENT);
            }

            dc.drawText(
                width / 2,
                (height / 2) - 10,
                font,
                statusText,
                Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
            );

            // Diagnostics & Waves info text
            dc.setColor(textColor, Graphics.COLOR_TRANSPARENT);
            var accelStatus = mHasAccelData ? "OK" : "NO_ACC";
            var debugText = "V:" + mCurrentVariance.format("%.0f") + " | " + accelStatus + " | W:" + mTotalWaves.toString();
            
            if (height >= 50) {
                dc.drawText(
                    width / 2,
                    height - 12,
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
