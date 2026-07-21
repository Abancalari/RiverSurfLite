import Toybox.WatchUi;
import Toybox.Graphics;
import Toybox.Activity;
import Toybox.ActivityRecording;
import Toybox.FitContributor;
import Toybox.Sensor;
import Toybox.Position;
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

    // Page navigation index (0: Main Surf Activity Page, 1: Wave History Page)
    private var mCurrentPage = 0;
    private const TOTAL_PAGES = 2;
    private var mGpsAccuracy = 0;

    // Wave statistics
    private var mTotalWaves = 0;
    private var mTotalSurfingTime = 0;
    private var mElapsedTime = 0;
    private var mCurrentWaveDuration = 0;
    private var mLongestWaveDuration = 0;
    private var mMaxWaveSpeed = 0.0;
    private var mWaveRegistered = false;
    private var mWaveHistory = [];

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
        try {
            Position.enableLocationEvents(Position.LOCATION_CONTINUOUS, method(:onPosition));
        } catch (e) {
        }
    }

    function onHide() {
        mTimer.stop();
        try {
            Position.enableLocationEvents(Position.LOCATION_DISABLE, method(:onPosition));
        } catch (e) {
        }
    }

    function onPosition(info as Position.Info) as Void {
        if (info != null) {
            if (info.speed != null) {
                mSpeed = info.speed;
            }
            if (info.accuracy != null) {
                mGpsAccuracy = info.accuracy;
            }
        }
    }

    function onTimerTick() {
        if (mSession != null && mSession.isRecording()) {
            mElapsedTime += 1;
        }
        compute();
        WatchUi.requestUpdate();
    }

    private var mLastPageLoaded = -1;

    function onLayout(dc) {
        mLastPageLoaded = mCurrentPage;
        if (mCurrentPage == 0) {
            setLayout(Rez.Layouts.MainLayout(dc));
        } else if (mCurrentPage == 1) {
            setLayout(Rez.Layouts.LapsLayout(dc));
        }
    }

    function nextPage() {
        mCurrentPage = (mCurrentPage + 1) % TOTAL_PAGES;
        WatchUi.requestUpdate();
    }

    function previousPage() {
        mCurrentPage = (mCurrentPage - 1 + TOTAL_PAGES) % TOTAL_PAGES;
        WatchUi.requestUpdate();
    }

    function onUpdate(dc) {
        if (mLastPageLoaded != mCurrentPage) {
            onLayout(dc);
        }

        if (mCurrentPage == 0) {
            var elapsedTime = View.findDrawableById("ElapsedTime") as Text;
            if (elapsedTime != null) {
                var elMins = mElapsedTime / 60;
                var elSecs = mElapsedTime % 60;
                elapsedTime.setText(elMins.format("%02d") + ":" + elSecs.format("%02d"));
            }

            var waveLabel = View.findDrawableById("WaveCount") as Text;
            if (waveLabel != null) {
                waveLabel.setText(mTotalWaves.toString());
            }

            var surfTime = View.findDrawableById("SurfTime") as Text;
            if (surfTime != null) {
                var surfMins = mTotalSurfingTime / 60;
                var surfSecs = mTotalSurfingTime % 60;
                surfTime.setText(surfMins.format("%02d") + ":" + surfSecs.format("%02d"));
            }

            var clockTime = View.findDrawableById("ClockTime") as Text;
            if (clockTime != null) {
                var tod = System.getClockTime();
                clockTime.setText(tod.hour.format("%02d") + ":" + tod.min.format("%02d"));
            }

            View.onUpdate(dc);

            // Draw full-width horizontal white status banner in the center
            var width = dc.getWidth();
            var height = dc.getHeight();
            var bannerY = (height * 0.432).toNumber(); // y = 76 on 176px Instinct 2
            var bannerH = (height * 0.193).toNumber(); // height = 34px

            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_WHITE);
            dc.fillRectangle(0, bannerY, width, bannerH);

            var statusStr = "[ WAITING ]";
            if (mSession == null || !mSession.isRecording()) {
                if (mGpsAccuracy < 3) {
                    statusStr = "[ FINDING GPS ]";
                } else {
                    statusStr = "[ READY ]";
                }
            } else {
                if (mState == STATE_SURFING) {
                    statusStr = "[ SURFING! ]";
                } else if (mState == STATE_SWEPT) {
                    statusStr = "[ SWEPT ]";
                } else {
                    statusStr = "[ WAITING ]";
                }
            }

            dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
            dc.drawText(width / 2, bannerY + bannerH / 2, Graphics.FONT_MEDIUM, statusStr, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

            // Draw bottom split divider line between Surf Time and TOD
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            dc.drawLine(width / 2, (height * 0.647).toNumber(), width / 2, (height * 0.954).toNumber());

        } else if (mCurrentPage == 1) {
            var subWaveCount = View.findDrawableById("SubWaveCount") as Text;
            if (subWaveCount != null) {
                subWaveCount.setText(mTotalWaves.toString());
            }

            var totalCount = mWaveHistory.size();
            var lapsHeader = View.findDrawableById("LapsHeader") as Text;
            if (lapsHeader != null) {
                lapsHeader.setText("WAVES:");
            }

            var item1 = View.findDrawableById("LapItem1") as Text;
            var item2 = View.findDrawableById("LapItem2") as Text;
            var item3 = View.findDrawableById("LapItem3") as Text;

            if (totalCount == 0) {
                if (item1 != null) { item1.setText("NO WAVES YET"); }
                if (item2 != null) { item2.setText(""); }
                if (item3 != null) { item3.setText(""); }
            } else {
                if (item1 != null) {
                    var idx1 = totalCount - 1;
                    item1.setText("#" + (idx1 + 1).toString() + ": " + mWaveHistory[idx1].toString() + "s");
                }
                if (item2 != null) {
                    if (totalCount >= 2) {
                        var idx2 = totalCount - 2;
                        item2.setText("#" + (idx2 + 1).toString() + ": " + mWaveHistory[idx2].toString() + "s");
                    } else {
                        item2.setText("");
                    }
                }
                if (item3 != null) {
                    if (totalCount >= 3) {
                        var idx3 = totalCount - 3;
                        item3.setText("#" + (idx3 + 1).toString() + ": " + mWaveHistory[idx3].toString() + "s");
                    } else {
                        item3.setText("");
                    }
                }
            }

            View.onUpdate(dc);
        }
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
                            if (mWaveRegistered) {
                                mWaveHistory.add(mCurrentWaveDuration);
                                if (mSession != null && mSession.isRecording()) {
                                    mSession.addLap();
                                }
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

    private var mMenuOpen = false;

    // Session Management & Menu Controls
    function onStartStopPressed() {
        if (mSession == null) {
            startSession();
            mCurrentPage = 1;
        } else if (mSession.isRecording()) {
            mSession.stop();
            showPauseMenu();
        } else {
            if (!mMenuOpen) {
                showPauseMenu();
            } else {
                resumeSession();
            }
        }
        WatchUi.requestUpdate();
    }

    function onBackPressed() {
        if (mSession != null) {
            if (mSession.isRecording()) {
                mSession.stop();
            }
            showPauseMenu();
            return true;
        }
        return false;
    }

    function toggleRecording() {
        onStartStopPressed();
    }

    function startSession() {
        if (mSession == null) {
            mSession = ActivityRecording.createSession({
                :name => "River Surfing",
                :sport => ActivityRecording.SPORT_SURFING,
                :subSport => ActivityRecording.SUB_SPORT_GENERIC
            });

            mWaveCountField = mSession.createField(
                "wave_count", 0, FitContributor.DATA_TYPE_UINT16,
                {
                    :mesgType => FitContributor.MESG_TYPE_SESSION,
                    :label => "Wave Count",
                    :units => "waves",
                    :count => 1,
                    :nativeNum => 26
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
        mMenuOpen = false;
        WatchUi.requestUpdate();
    }

    function resumeSession() {
        mMenuOpen = false;
        if (mSession != null && !mSession.isRecording()) {
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
        mMenuOpen = false;
        if (mSession != null) {
            // Flush final FIT field values right before stopping and saving
            updateFitFields();

            if (mSession.isRecording()) {
                mSession.stop();
            }
            mSession.save();
            mSession = null;

            var summaryView = new RiverSurfSummaryView(mTotalWaves, mTotalSurfingTime, mLongestWaveDuration, mMaxWaveSpeed);
            var summaryDelegate = new RiverSurfSummaryDelegate();

            mTotalWaves = 0;
            mTotalSurfingTime = 0;
            mElapsedTime = 0;
            mMaxWaveSpeed = 0.0;
            mLongestWaveDuration = 0;
            mWaveHistory = [];
            mState = STATE_WAITING;

            WatchUi.pushView(summaryView, summaryDelegate, WatchUi.SLIDE_IMMEDIATE);
        }
        WatchUi.requestUpdate();
    }

    function discardSession() {
        mMenuOpen = false;
        if (mSession != null) {
            if (mSession.isRecording()) {
                mSession.stop();
            }
            mSession.discard();
            mSession = null;
            mTotalWaves = 0;
            mTotalSurfingTime = 0;
            mElapsedTime = 0;
            mMaxWaveSpeed = 0.0;
            mLongestWaveDuration = 0;
            mWaveHistory = [];
            mState = STATE_WAITING;
        }
        WatchUi.requestUpdate();
    }

    function showPauseMenu() {
        if (!mMenuOpen) {
            mMenuOpen = true;
            var menu = new WatchUi.Menu();
            menu.setTitle("Session Menu");
            menu.addItem("Resume", :itemResume);
            menu.addItem("Diagnostics", :itemDiag);
            menu.addItem("Save", :itemSave);
            menu.addItem("Discard", :itemDiscard);

            WatchUi.pushView(menu, new RiverSurfMenuDelegate(self), WatchUi.SLIDE_IMMEDIATE);
        }
    }

    function showDiagnosticsView() {
        mMenuOpen = false;
        var diagView = new RiverSurfDiagView(self);
        var diagDelegate = new RiverSurfDiagDelegate();
        WatchUi.pushView(diagView, diagDelegate, WatchUi.SLIDE_IMMEDIATE);
    }

    function hasAccelData() { return mHasAccelData; }
    function getCarveVariance() { return mCurrentVariance; }
    function getSpeed() { return mSpeed; }
}
