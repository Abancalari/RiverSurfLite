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

    // Current accelerometer magnitude in millig
    private var mCurrentAccelMag = 1000.0;

    // Thresholds
    private const SURF_ACCEL_VAR_THRESHOLD = 20000.0;
    private const SWEEP_SPEED_THRESHOLD = 2.5;

    function initialize() {
        DataField.initialize();

        // Custom FIT Field IDs: Count (0, SESSION), Time (1, SESSION), Duration (2, RECORD)
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

        // Register accelerometer listener to receive 1Hz sensor updates
        try {
            Sensor.registerSensorDataListener(method(:onAccelData), {
                :period => 1,
                :accelerometer => { :enabled => true }
            });
        } catch (e) {
            // Devices without sensor listener fallback to Sensor.getInfo()
        }
    }

    // Callback received when accelerometer sample is ready with strict type annotation
    function onAccelData(sensorData as Sensor.SensorData) as Void {
        if (sensorData != null && sensorData.accelerometerData != null) {
            var x = sensorData.accelerometerData.x;
            var y = sensorData.accelerometerData.y;
            var z = sensorData.accelerometerData.z;
            if (x != null && x.size() > 0 && y != null && z != null) {
                var ax = x[0].toFloat();
                var ay = y[0].toFloat();
                var az = z[0].toFloat();
                mCurrentAccelMag = Math.sqrt(ax * ax + ay * ay + az * az);
            }
        }
    }

    function compute(info) {
        var speed = (info != null && info.currentSpeed != null) ? info.currentSpeed : 0.0;

        // Fallback to Sensor.getInfo() if listener callback hasn't updated
        var accelMag = mCurrentAccelMag;
        var sensorInfo = Sensor.getInfo();
        if (sensorInfo != null && sensorInfo.accel != null) {
            var ax = sensorInfo.accel[0].toFloat();
            var ay = sensorInfo.accel[1].toFloat();
            var az = sensorInfo.accel[2].toFloat();
            accelMag = Math.sqrt(ax * ax + ay * ay + az * az);
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

        return null;
    }

    function onUpdate(dc) {
        var rawBg = getBackgroundColor();
        var isDark = (rawBg == Graphics.COLOR_BLACK || rawBg == Graphics.COLOR_DK_GRAY);

        var bgColor = isDark ? Graphics.COLOR_BLACK : Graphics.COLOR_WHITE;
        var textColor = isDark ? Graphics.COLOR_WHITE : Graphics.COLOR_BLACK;

        dc.setColor(bgColor, bgColor);
        dc.clear();

        dc.setColor(textColor, Graphics.COLOR_TRANSPARENT);

        var statusText = "WAITING";
        if (mState == STATE_SURFING) {
            statusText = "SURFING";
        } else if (mState == STATE_SWEPT) {
            statusText = "SWEPT";
        }

        var width = dc.getWidth();
        var height = dc.getHeight();

        var font = Graphics.FONT_MEDIUM;
        if (height < 50) {
            font = Graphics.FONT_SMALL;
        } else if (height > 90) {
            font = Graphics.FONT_LARGE;
        }

        dc.drawText(
            width / 2,
            height / 2,
            font,
            statusText,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );
    }
}
