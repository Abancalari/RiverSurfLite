import Toybox.WatchUi;
import Toybox.Graphics;
import Toybox.Activity;
import Toybox.ActivityRecording;
import Toybox.FitContributor;
import Toybox.Sensor;
import Toybox.Math;
import Toybox.Timer;
import Toybox.System;

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

    // Page navigation index (0: Primary Page, 1: Diagnostics Page)
    private var mCurrentPage = 0;
    private const TOTAL_PAGES = 2;

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
                        }

                        if (mCurrentWaveDuration >= 3 && !mWaveRegistered) {
                            mTotalWaves += 1;
                            mWaveRegistered = true;
                        }

                        if (mWaveRegistered) {
                            mTotalSurfingTime += 1;
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
                            }
                        }
                        break;

                    case STATE_SWEPT:
                        if (mSpeed < SWEEP_SPEED_THRESHOLD) {
                            mState = STATE_WAITING;
                        }
                        break;
                }

                // Continuously sync active data to FIT fields during recording
                updateFitFields();
            } else {
                mState = STATE_WAITING;
            }
        } catch (e) {
            // Keep state intact
        }
    }

    // Explicitly update all FIT session & record fields
    private function updateFitFields() {
        if (mWaveCountField != null) {
            mWaveCountField.setData(mTotalWaves);
        }
        if (mTimeSurfingField != null) {
            mTimeSurfingField.setData(mTotalSurfingTime);
        }
        if (mMaxWaveSpeedField != null) {
            mMaxWaveSpeedField.setData(mMaxWaveSpeed);
        }
        if (mLongestWaveField != null) {
            mLongestWaveField.setData(mLongestWaveDuration);
        }
        if (mWaveDurationField != null) {
            var dur = (mState == STATE_SURFING) ? mCurrentWaveDuration : 0;
            mWaveDurationField.setData(dur);
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
                :name => "River Surf Lite",
                :sport => ActivityRecording.SPORT_SURFING,
                :subSport => ActivityRecording.SUB_SPORT_GENERIC
            });

            mWaveCountField = mSession.createField(
                "wave_count", 0, FitContributor.DATA_TYPE_UINT16,
                {
                    :mesgType => FitContributor.MESG_TYPE_SESSION,
                    :label => "Wave Count",
                    :units => "waves",
                    :count => 1
                }
            );
            mTimeSurfingField = mSession.createField(
                "time_surfing", 1, FitContributor.DATA_TYPE_UINT32,
                {
                    :mesgType => FitContributor.MESG_TYPE_SESSION,
                    :label => "Surf Time",
                    :units => "s",
                    :count => 1
                }
            );
            mMaxWaveSpeedField = mSession.createField(
                "max_wave_speed", 2, FitContributor.DATA_TYPE_FLOAT,
                {
                    :mesgType => FitContributor.MESG_TYPE_SESSION,
                    :label => "Max Surf Speed",
                    :units => "m/s",
                    :count => 1
                }
            );
            mLongestWaveField = mSession.createField(
                "longest_wave_time", 3, FitContributor.DATA_TYPE_UINT16,
                {
                    :mesgType => FitContributor.MESG_TYPE_SESSION,
                    :label => "Longest Wave",
                    :units => "s",
                    :count => 1
                }
            );
            mWaveDurationField = mSession.createField(
                "wave_duration", 4, FitContributor.DATA_TYPE_UINT16,
                {
                    :mesgType => FitContributor.MESG_TYPE_RECORD,
                    :label => "Wave Duration",
                    :units => "s",
                    :count => 1
                }
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
            // Flush final FIT field values right before stopping and saving
            updateFitFields();

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

    function onUpdate(dc) {
        if (mCurrentPage == 0) {
            // 1. Black Background
            dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
            dc.clear();

            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);

            // ----------------------------------------------------
            // 1. Top-Left Header Zone (State Flag)
            // ----------------------------------------------------
            var stateLabel = "[READY]";
            if (mSession != null && mSession.isRecording()) {
                stateLabel = "[REC]";
            }
            dc.drawText(10, 26, Graphics.FONT_TINY, stateLabel, Graphics.TEXT_JUSTIFY_LEFT);

            // ----------------------------------------------------
            // 2. Sub-Window Lens (Circle Lens in Top-Right)
            // ----------------------------------------------------
            var subCenterX = 142;
            dc.drawText(subCenterX, 20, Graphics.FONT_XTINY, "WAVES", Graphics.TEXT_JUSTIFY_CENTER);
            dc.drawText(subCenterX, 44, Graphics.FONT_MEDIUM, mTotalWaves.toString(), Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

            // ----------------------------------------------------
            // 3. Main Status Banner (Center)
            // ----------------------------------------------------
            var statusText = "[ WAITING ]";
            if (mState == STATE_SURFING) {
                statusText = "[ SURFING! ]";
            } else if (mState == STATE_SWEPT) {
                statusText = "[ SWEPT ]";
            }

            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_WHITE);
            dc.fillRectangle(0, 76, 176, 34);

            dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
            dc.drawText(88, 93, Graphics.FONT_MEDIUM, statusText, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);

            // ----------------------------------------------------
            // 4. Bottom Split Layout (Surf Time | Time of Day)
            // ----------------------------------------------------
            dc.drawLine(88, 114, 88, 168);

            dc.drawText(44, 118, Graphics.FONT_XTINY, "SURF TIME", Graphics.TEXT_JUSTIFY_CENTER);
            
            var surfMins = mTotalSurfingTime / 60;
            var surfSecs = mTotalSurfingTime % 60;
            var surfTimeString = surfMins.format("%02d") + ":" + surfSecs.format("%02d");
            dc.drawText(44, 138, Graphics.FONT_TINY, surfTimeString, Graphics.TEXT_JUSTIFY_CENTER);

            dc.drawText(132, 118, Graphics.FONT_XTINY, "TOD", Graphics.TEXT_JUSTIFY_CENTER);

            var clockTime = System.getClockTime();
            var todString = clockTime.hour.format("%02d") + ":" + clockTime.min.format("%02d");
            dc.drawText(132, 138, Graphics.FONT_TINY, todString, Graphics.TEXT_JUSTIFY_CENTER);

        } else if (mCurrentPage == 1) {
            // PAGE 2: Sensor & Motion Diagnostics
            dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
            dc.clear();
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);

            dc.drawText(88, 64, Graphics.FONT_XTINY, "DIAGNOSTICS", Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

            var accelStr = mHasAccelData ? "ACCEL: STREAMING (25Hz)" : "ACCEL: WAITING";
            dc.drawText(88, 84, Graphics.FONT_XTINY, accelStr, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

            var varStr = "CARVE VARIANCE: " + mCurrentVariance.format("%.0f");
            dc.drawText(88, 104, Graphics.FONT_XTINY, varStr, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

            var speedKmhStr = "GPS SPEED: " + (mSpeed * 3.6).format("%.1f") + " km/h";
            dc.drawText(88, 124, Graphics.FONT_XTINY, speedKmhStr, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

            var pageStr = "PAGE 2/2 (UP/DN SCROLL)";
            dc.drawText(88, 142, Graphics.FONT_XTINY, pageStr, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        }
    }
}
