import Toybox.WatchUi;
import Toybox.Graphics;
import Toybox.System;
import Toybox.Activity;
import Toybox.ActivityRecording;
import Toybox.FitContributor;
import Toybox.Sensor;
import Toybox.Math;
import Toybox.Timer;

class RiverSurfView extends WatchUi.DataField {

    // Fit Field IDs
    private const FIT_WAVE_COUNT_FIELD_ID = 0;
    private const FIT_TIME_SURFING_FIELD_ID = 1;
    private const FIT_WAVE_DURATION_FIELD_ID = 2;

    // Fit Fields
    private var mWaveCountField = null;
    private var mTimeSurfingField = null;
    private var mWaveDurationField = null;

    // Recording Session
    private var mSession = null;

    // Surfing states
    public enum SurfState {
        STATE_WAITING = 0,
        STATE_SURFING = 1,
        STATE_SWEPT = 2
    }

    private var mState = STATE_WAITING;

    // Wave statistics
    private var mTotalWaves = 0;
    private var mTotalSurfingTime = 0; // in seconds
    private var mCurrentWaveDuration = 0; // in seconds
    private var mWaveRegistered = false;

    // Rolling buffer for accelerometer magnitude (last 5 seconds)
    private const BUFFER_SIZE = 5;
    private var mAccelBuffer = new [BUFFER_SIZE];
    private var mBufferIndex = 0;
    private var mBufferFull = false;

    // Thresholds
    // High accel variance indicates active carving/surfing
    private const SURF_ACCEL_VAR_THRESHOLD = 20000.0; // millig^2
    // GPS Speed threshold in m/s (2.5 m/s = 9 km/h)
    private const SWEEP_SPEED_THRESHOLD = 2.5;

    // Timer
    private var mTimer;

    // Current values for display
    private var mSpeed = 0.0;
    private var mHeartRate = 0;
    private var mGpsAccuracy = 0;

    function initialize() {
        DataField.initialize();

        // Properly initialize DataField Fit Contributor Fields
        mWaveCountField = createField("wave_count", 0, Toybox.FitContributor.DATA_TYPE_UINT16, { :mesgType => Toybox.FitContributor.MESG_TYPE_SESSION, :label => "Waves" });
        mTimeSurfingField = createField("time_surfing", 1, Toybox.FitContributor.DATA_TYPE_UINT32, { :mesgType => Toybox.FitContributor.MESG_TYPE_SESSION, :label => "Time Surfing", :units => "s" });
        mWaveDurationField = createField("wave_duration", 2, Toybox.FitContributor.DATA_TYPE_UINT16, { :mesgType => Toybox.FitContributor.MESG_TYPE_RECORD, :label => "Wave Duration", :units => "s" });

        // Initialize accelerometer rolling buffer
        for (var i = 0; i < BUFFER_SIZE; i++) {
            mAccelBuffer[i] = 1000.0; // 1G default
        }

        // Setup timer to run update every 1 second
        mTimer = new Timer.Timer();
    }

    function onShow() {
        // Start timer
        mTimer.start(method(:onTimerTick), 1000, true);
    }

    function onHide() {
        mTimer.stop();
    }

    // Called once per second by our timer
    function onTimerTick() {
        // Get activity info
        var info = Activity.getActivityInfo();
        var timerActive = (mSession != null && mSession.isRecording());

        // Update GPS accuracy, speed and heart rate
        if (info != null) {
            mSpeed = (info.currentSpeed != null) ? info.currentSpeed : 0.0;
            mHeartRate = (info.currentHeartRate != null) ? info.currentHeartRate : 0;
            mGpsAccuracy = (info.currentLocationAccuracy != null) ? info.currentLocationAccuracy : 0;
        }

        // Only run wave detection if we are actively recording
        if (timerActive) {
            // 1. Process Accelerometer
            var accelMag = 1000.0;
            var sensorInfo = Sensor.getInfo();
            if (sensorInfo != null && sensorInfo.accel != null) {
                var ax = sensorInfo.accel[0].toFloat();
                var ay = sensorInfo.accel[1].toFloat();
                var az = sensorInfo.accel[2].toFloat();
                accelMag = Math.sqrt(ax * ax + ay * ay + az * az);
            }

            mAccelBuffer[mBufferIndex] = accelMag;
            mBufferIndex = (mBufferIndex + 1) % BUFFER_SIZE;
            if (mBufferIndex == 0) {
                mBufferFull = true;
            }

            // Calculate variance
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

            // 2. Wave Detection State Machine
            switch (mState) {
                case STATE_WAITING:
                    if (variance > SURF_ACCEL_VAR_THRESHOLD && mSpeed < SWEEP_SPEED_THRESHOLD) {
                        mState = STATE_SURFING;
                        mCurrentWaveDuration = 0;
                        mWaveRegistered = false;
                    }
                    break;

                case STATE_SURFING:
                    mCurrentWaveDuration += 1;

                    // Log wave if surfing lasted at least 3 seconds
                    if (mCurrentWaveDuration >= 3 && !mWaveRegistered) {
                        mTotalWaves += 1;
                        mWaveRegistered = true;
                        if (mWaveCountField != null) {
                            mWaveCountField.setData(mTotalWaves);
                        }
                    }

                    // Increment total surfing time
                    if (mWaveRegistered) {
                        mTotalSurfingTime += 1;
                        if (mTimeSurfingField != null) {
                            mTimeSurfingField.setData(mTotalSurfingTime);
                        }
                    }

                    // Log current wave duration
                    if (mWaveDurationField != null) {
                        mWaveDurationField.setData(mCurrentWaveDuration);
                    }

                    // Transitions out
                    if (mSpeed >= SWEEP_SPEED_THRESHOLD) {
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
                    if (mSpeed < SWEEP_SPEED_THRESHOLD) {
                        mState = STATE_WAITING;
                    }
                    break;
            }
        } else {
            // When paused/stopped, ensure current wave duration shows 0
            if (mWaveDurationField != null) {
                mWaveDurationField.setData(0);
            }
        }

        // Request UI repaint
        WatchUi.requestUpdate();
    }

    // Toggle Recording (called by Delegate)
    function toggleRecording() {
        WatchUi.requestUpdate();
    }

    // Check if session is recording
    function isRecording() {
        return mSession != null && mSession.isRecording();
    }

    // Check if session exists
    function hasSession() {
        return mSession != null;
    }

    // Save session
    function saveSession() {
        if (mSession != null) {
            mSession.save();
            mSession = null;
            mTotalWaves = 0;
            mTotalSurfingTime = 0;
            mState = STATE_WAITING;
        }
        WatchUi.requestUpdate();
    }

    // Discard session
    function discardSession() {
        if (mSession != null) {
            mSession.discard();
            mSession = null;
            mTotalWaves = 0;
            mTotalSurfingTime = 0;
            mState = STATE_WAITING;
        }
        WatchUi.requestUpdate();
    }

    // Get current state
    function getSurfState() {
        return mState;
    }

    function getWaves() {
        return mTotalWaves;
    }

    function getSurfingTime() {
        return mTotalSurfingTime;
    }

    // Drawing the UI with Rich Aesthetics
    function onUpdate(dc) {
        // Sleek black/dark background
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();

        var width = dc.getWidth();
        var height = dc.getHeight();
        var centerX = width / 2;

        // Draw top header bar
        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.fillRectangle(0, 0, width, 40);

        // Draw GPS Status & Title in Header
        var gpsColor = Graphics.COLOR_RED;
        if (mGpsAccuracy >= 3) {
            gpsColor = Graphics.COLOR_GREEN;
        } else if (mGpsAccuracy == 2) {
            gpsColor = Graphics.COLOR_YELLOW;
        }
        dc.setColor(gpsColor, Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(centerX - 60, 20, 5); // GPS dot

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(centerX, 20, Graphics.FONT_XTINY, "RIVER SURF", Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        // State indicator color
        var stateColor = Graphics.COLOR_WHITE;
        var stateStr = "WAITING";
        if (isRecording()) {
            if (mState == STATE_SURFING) {
                stateColor = 0x00A0FF; // Rich Cyan
                stateStr = "SURFING!";
            } else if (mState == STATE_SWEPT) {
                stateColor = 0xFF5500; // Orange-red
                stateStr = "SWEPT";
            } else {
                stateColor = Graphics.COLOR_GREEN;
                stateStr = "ON WAVE SPOT";
            }
        } else {
            stateColor = Graphics.COLOR_RED;
            stateStr = "PAUSED";
        }

        // Draw wave count central badge (large circle)
        var circleRadius = 55;
        var circleY = height / 2 - 5;
        dc.setColor(stateColor, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(4);
        dc.drawCircle(centerX, circleY, circleRadius);

        // Fill background of circle slightly for depth
        dc.setColor(0x111111, Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(centerX, circleY, circleRadius - 2);

        // Draw Wave Count value inside the circle
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(centerX, circleY - 18, Graphics.FONT_NUMBER_HOT, mTotalWaves.toString(), Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(centerX, circleY + 22, Graphics.FONT_XTINY, "WAVES", Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        // Draw secondary stats under the badge
        var statsY = height / 2 + 65;
        
        // Speed in km/h
        var speedKmh = mSpeed * 3.6;
        var speedStr = speedKmh.format("%.1f") + " km/h";
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(centerX - 45, statsY, Graphics.FONT_TINY, speedStr, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(centerX - 45, statsY + 18, Graphics.FONT_XTINY, "SPEED", Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        // Heart Rate
        var hrStr = (mHeartRate > 0) ? mHeartRate.toString() : "--";
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(centerX + 45, statsY, Graphics.FONT_TINY, hrStr + " bpm", Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(centerX + 45, statsY + 18, Graphics.FONT_XTINY, "HEART", Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        // Divider
        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawLine(centerX, statsY - 10, centerX, statsY + 25);

        // Bottom status bar
        dc.setColor(stateColor, Graphics.COLOR_TRANSPARENT);
        dc.fillRectangle(0, height - 30, width, 30);
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
        dc.drawText(centerX, height - 15, Graphics.FONT_XTINY, stateStr, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }
}
