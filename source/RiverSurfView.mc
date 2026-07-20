import Toybox.WatchUi;
import Toybox.Graphics;
import Toybox.Activity;
import Toybox.ActivityRecording;
import Toybox.FitContributor;
import Toybox.Sensor;
import Toybox.Math;
import Toybox.Timer;

class RiverSurfView extends WatchUi.View {

    // FIT Contributor Fields
    private var mWaveCountField = null;
    private var mTimeSurfingField = null;
    private var mMaxWaveSpeedField = null;
    private var mLongestWaveField = null;
    private var mWaveDurationField = null;

    // Recording Session
    private var mSession = null;

    // Surfing states
    enum SurfState {
        STATE_WAITING = 0,
        STATE_SURFING = 1,
        STATE_SWEPT = 2
    }

    private var mState = STATE_WAITING;

    // Page navigation index (0: Status, 1: Metrics, 2: Diagnostics)
    private var mCurrentPage = 0;
    private const TOTAL_PAGES = 3;

    // Wave statistics
    private var mTotalWaves = 0;
    private var mTotalSurfingTime = 0;
    private var mCurrentWaveDuration = 0;
    private var mLongestWaveDuration = 0;
    private var mMaxWaveSpeed = 0.0;
    private var mWaveRegistered = false;

    // Rolling buffer for accelerometer magnitude (5 seconds)
    private const BUFFER_SIZE = 5;
    private var mAccelBuffer = [1000.0, 1000.0, 1000.0, 1000.0, 1000.0];
    private var mBufferIndex = 0;
    private var mLastAccelMag = 1000.0;
    private var mCurrentVariance = 0.0;
    private var mHasAccelData = false;

    // Thresholds
    private const SURF_ACCEL_VAR_THRESHOLD = 5000.0; // millig^2
    private const SWEEP_SPEED_THRESHOLD = 2.5;     // 2.5 m/s = 9 km/h

    // Timer & Metrics
    private var mTimer;
    private var mSpeed = 0.0;
    private var mHeartRate = 0;

    function initialize() {
        View.initialize();

        mTimer = new Timer.Timer();

        // Register high-frequency accelerometer listener
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

    function onShow() {
        mTimer.start(method(:onTimerTick), 1000, true);
    }

    function onHide() {
        mTimer.stop();
    }

    function onTimerTick() {
        compute();
        WatchUi.requestUpdate();
    }

    // Page navigation methods called by Delegate
    function nextPage() {
        mCurrentPage = (mCurrentPage + 1) % TOTAL_PAGES;
        WatchUi.requestUpdate();
    }

    function previousPage() {
        mCurrentPage = (mCurrentPage - 1 + TOTAL_PAGES) % TOTAL_PAGES;
        WatchUi.requestUpdate();
    }

    function compute() {
        try {
            var info = Activity.getActivityInfo();
            if (info != null) {
                if (info.currentSpeed != null) {
                    mSpeed = info.currentSpeed;
                } else {
                    mSpeed = 0.0;
                }
                if (info.currentHeartRate != null) {
                    mHeartRate = info.currentHeartRate;
                } else {
                    mHeartRate = 0;
                }
            }

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

            // Only update wave state when active recording session is running
            if (mSession != null && mSession.isRecording()) {
                switch (mState) {
                    case STATE_WAITING:
                        if (mCurrentVariance > SURF_ACCEL_VAR_THRESHOLD && mSpeed < SWEEP_SPEED_THRESHOLD) {
                            mState = STATE_SURFING;
                            mCurrentWaveDuration = 0;
                            mWaveRegistered = false;
                        }
                        break;

                    case STATE_SURFING:
                        mCurrentWaveDuration += 1;

                        if (mSpeed > mMaxWaveSpeed) {
                            mMaxWaveSpeed = mSpeed;
                            if (mMaxWaveSpeedField != null) {
                                mMaxWaveSpeedField.setData(mMaxWaveSpeed);
                            }
                        }

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

                        var endWave = false;
                        if (mSpeed >= SWEEP_SPEED_THRESHOLD) {
                            mState = STATE_SWEPT;
                            endWave = true;
                        } else if (mCurrentVariance <= SURF_ACCEL_VAR_THRESHOLD) {
                            mState = STATE_WAITING;
                            endWave = true;
                        }

                        if (endWave) {
                            if (mCurrentWaveDuration > mLongestWaveDuration) {
                                mLongestWaveDuration = mCurrentWaveDuration;
                                if (mLongestWaveField != null) {
                                    mLongestWaveField.setData(mLongestWaveDuration);
                                }
                            }
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
                mState = STATE_WAITING;
            }
        } catch (e) {
            // Keep state intact
        }
    }

    // Session Management
    function toggleRecording() {
        if (mSession == null) {
            startSession();
        } else if (mSession.isRecording()) {
            mSession.stop();
        } else {
            mSession.start();
        }
        WatchUi.requestUpdate();
    }

    function startSession() {
        if (mSession == null) {
            mSession = ActivityRecording.createSession({
                :name => "River Surf",
                :sport => ActivityRecording.SPORT_SURFING,
                :subSport => ActivityRecording.SUB_SPORT_GENERIC
            });

            mWaveCountField = mSession.createField(
                "wave_count", 0, FitContributor.DATA_TYPE_UINT16,
                { :mesgType => FitContributor.MESG_TYPE_SESSION, :label => "Waves" }
            );
            mTimeSurfingField = mSession.createField(
                "time_surfing", 1, FitContributor.DATA_TYPE_UINT32,
                { :mesgType => FitContributor.MESG_TYPE_SESSION, :label => "Surf Time", :units => "s" }
            );
            mMaxWaveSpeedField = mSession.createField(
                "max_wave_speed", 2, FitContributor.DATA_TYPE_FLOAT,
                { :mesgType => FitContributor.MESG_TYPE_SESSION, :label => "Max Surf Speed", :units => "m/s" }
            );
            mLongestWaveField = mSession.createField(
                "longest_wave_time", 3, FitContributor.DATA_TYPE_UINT16,
                { :mesgType => FitContributor.MESG_TYPE_SESSION, :label => "Longest Wave", :units => "s" }
            );
            mWaveDurationField = mSession.createField(
                "wave_duration", 4, FitContributor.DATA_TYPE_UINT16,
                { :mesgType => FitContributor.MESG_TYPE_RECORD, :label => "Wave Duration", :units => "s" }
            );

            mSession.start();
        } else if (!mSession.isRecording()) {
            mSession.start();
        }
        WatchUi.requestUpdate();
    }

    function isRecording() {
        return mSession != null && mSession.isRecording();
    }

    function hasSession() {
        return mSession != null;
    }

    function saveSession() {
        if (mSession != null) {
            if (mSession.isRecording()) {
                mSession.stop();
            }
            mSession.save();
            mSession = null;
            mTotalWaves = 0;
            mTotalSurfingTime = 0;
            mMaxWaveSpeed = 0.0;
            mLongestWaveDuration = 0;
            mState = STATE_WAITING;
        }
        WatchUi.requestUpdate();
    }

    function discardSession() {
        if (mSession != null) {
            if (mSession.isRecording()) {
                mSession.stop();
            }
            mSession.discard();
            mSession = null;
            mTotalWaves = 0;
            mTotalSurfingTime = 0;
            mMaxWaveSpeed = 0.0;
            mLongestWaveDuration = 0;
            mState = STATE_WAITING;
        }
        WatchUi.requestUpdate();
    }

    function showPauseMenu() {
        var menu = new WatchUi.Menu();
        menu.setTitle("Session Menu");
        menu.addItem("Resume", :itemResume);
        menu.addItem("Save", :itemSave);
        menu.addItem("Discard", :itemDiscard);

        WatchUi.pushView(menu, new RiverSurfMenuDelegate(self), WatchUi.SLIDE_IMMEDIATE);
    }

    // Format seconds into MM:SS
    private function formatTime(totalSeconds) {
        var mins = totalSeconds / 60;
        var secs = totalSeconds % 60;
        return mins.format("%02d") + ":" + secs.format("%02d");
    }

    function onUpdate(dc) {
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();

        var width = dc.getWidth();
        var height = dc.getHeight();

        // ----------------------------------------------------
        // 1. Instinct 2 Top-Right Sub-Window Circle (Wave Count)
        // ----------------------------------------------------
        var subCenterX = 138;
        var subCenterY = 38;
        var subRadius = 26;

        // Draw sub-window circle border
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(2);
        dc.drawCircle(subCenterX, subCenterY, subRadius);

        // Fill background for depth
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(subCenterX, subCenterY, subRadius - 1);

        // Sub-Window Contents (WAVES label + count)
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(subCenterX, subCenterY - 12, Graphics.FONT_XTINY, "WAVES", Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.drawText(subCenterX, subCenterY + 4, Graphics.FONT_MEDIUM, mTotalWaves.toString(), Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        // Reset Pen Width
        dc.setPenWidth(1);

        // ----------------------------------------------------
        // 2. Top Header & Recording Indicator
        // ----------------------------------------------------
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(42, 16, Graphics.FONT_XTINY, "RIVER SURF", Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        var recText = "[READY]";
        if (mSession != null) {
            if (mSession.isRecording()) {
                recText = "[REC]";
            } else {
                recText = "[PAUSED]";
            }
        }
        dc.drawText(42, 32, Graphics.FONT_XTINY, recText, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        // Horizontal Divider below header
        dc.drawLine(0, 52, width, 52);

        // ----------------------------------------------------
        // 3. Render Active Page Layout
        // ----------------------------------------------------
        if (mCurrentPage == 0) {
            // PAGE 0: Primary Status & Quick Metrics
            var statusText = "[ WAITING ]";
            if (mState == STATE_SURFING) {
                statusText = "SURFING!";
            } else if (mState == STATE_SWEPT) {
                statusText = "! SWEPT !";
            }

            // High-visibility Inverted Banner for SURFING
            if (mState == STATE_SURFING) {
                dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
                dc.fillRectangle(8, 62, width - 16, 38);
                dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
            } else {
                dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            }

            dc.drawText(
                width / 2,
                80,
                Graphics.FONT_LARGE,
                statusText,
                Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
            );

            // Divider
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            dc.drawLine(0, 110, width, 110);

            // Bottom Metrics
            var surfTimeStr = formatTime(mTotalSurfingTime);
            var maxSpeedStr = (mMaxWaveSpeed * 3.6).format("%.1f") + "k/h";

            dc.drawText(width / 4, 126, Graphics.FONT_XTINY, "SURF TIME", Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
            dc.drawText(width / 4, 145, Graphics.FONT_SMALL, surfTimeStr, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

            dc.drawText((3 * width) / 4, 126, Graphics.FONT_XTINY, "MAX SPEED", Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
            dc.drawText((3 * width) / 4, 145, Graphics.FONT_SMALL, maxSpeedStr, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

            // Vertical divider between bottom metrics
            dc.drawLine(width / 2, 110, width / 2, height);

        } else if (mCurrentPage == 1) {
            // PAGE 1: 4-Grid Surf Metrics
            var surfTimeStr = formatTime(mTotalSurfingTime);
            var longestStr = mLongestWaveDuration.toString() + "s";
            var maxSpeedStr = (mMaxWaveSpeed * 3.6).format("%.1f") + "k/h";
            var hrStr = (mHeartRate > 0) ? mHeartRate.toString() + "bpm" : "--";

            // Grid Dividers
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            dc.drawLine(width / 2, 52, width / 2, height);
            dc.drawLine(0, 110, width, 110);

            // Top-Left: Surf Time
            dc.drawText(width / 4, 66, Graphics.FONT_XTINY, "SURF TIME", Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
            dc.drawText(width / 4, 88, Graphics.FONT_SMALL, surfTimeStr, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

            // Top-Right: Longest Wave
            dc.drawText((3 * width) / 4, 66, Graphics.FONT_XTINY, "LONGEST", Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
            dc.drawText((3 * width) / 4, 88, Graphics.FONT_SMALL, longestStr, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

            // Bottom-Left: Max Speed
            dc.drawText(width / 4, 124, Graphics.FONT_XTINY, "MAX SPEED", Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
            dc.drawText(width / 4, 146, Graphics.FONT_SMALL, maxSpeedStr, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

            // Bottom-Right: Heart Rate
            dc.drawText((3 * width) / 4, 124, Graphics.FONT_XTINY, "HEART RATE", Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
            dc.drawText((3 * width) / 4, 146, Graphics.FONT_SMALL, hrStr, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        } else if (mCurrentPage == 2) {
            // PAGE 2: Sensor & Motion Diagnostics
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);

            dc.drawText(width / 2, 65, Graphics.FONT_XTINY, "DIAGNOSTICS", Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

            var accelStr = mHasAccelData ? "ACCEL: STREAMING (25Hz)" : "ACCEL: WAITING";
            dc.drawText(width / 2, 88, Graphics.FONT_XTINY, accelStr, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

            var varStr = "CARVE VARIANCE: " + mCurrentVariance.format("%.0f");
            dc.drawText(width / 2, 110, Graphics.FONT_XTINY, varStr, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

            var speedKmhStr = "GPS SPEED: " + (mSpeed * 3.6).format("%.1f") + " km/h";
            dc.drawText(width / 2, 132, Graphics.FONT_XTINY, speedKmhStr, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

            var pageStr = "PAGE 3/3 (UP/DN SCROLL)";
            dc.drawText(width / 2, 154, Graphics.FONT_XTINY, pageStr, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        }
    }
}
