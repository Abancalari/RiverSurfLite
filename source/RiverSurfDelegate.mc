import Toybox.WatchUi;
import Toybox.System;

class RiverSurfDelegate extends WatchUi.BehaviorDelegate {
    private var mView;

    function initialize(view) {
        BehaviorDelegate.initialize();
        mView = view;
    }

    // Top-Right / Select Button (Start/Pause/Menu)
    function onSelect() {
        if (mView != null) {
            mView.onStartStopPressed();
        }
        return true;
    }

    // UP button (Previous Page)
    function onPreviousPage() {
        if (mView != null) {
            mView.previousPage();
        }
        return true;
    }

    // DOWN button (Next Page)
    function onNextPage() {
        if (mView != null) {
            mView.nextPage();
        }
        return true;
    }

    // Back button (Pause / Resume Menu toggle)
    function onBack() {
        if (mView != null) {
            return mView.onBackPressed();
        }
        return false;
    }
}

class RiverSurfMenuDelegate extends WatchUi.MenuInputDelegate {
    private var mView;

    function initialize(view) {
        MenuInputDelegate.initialize();
        mView = view;
    }

    function onMenuItem(item) {
        if (mView != null) {
            if (item == :itemResume) {
                mView.resumeSession();
            } else if (item == :itemSave) {
                mView.saveSession();
            } else if (item == :itemDiscard) {
                mView.discardSession();
            } else if (item == :itemSettings) {
                mView.showSettingsMenu();
            } else if (item == :itemDiag) {
                mView.showDiagnosticsView();
            }
        }
    }
}

class RiverSurfSettingsMenuDelegate extends WatchUi.Menu2InputDelegate {
    private var mView;

    function initialize(view) {
        Menu2InputDelegate.initialize();
        mView = view;
    }

    function onSelect(item as WatchUi.MenuItem) as Void {
        if (mView != null) {
            var id = item.getId();
            if (id == :itemSetVar) {
                var newVal = mView.cycleAccelVarThreshold();
                item.setSubLabel(newVal.format("%.0f") + " mg²");
            } else if (id == :itemSetMinSpd) {
                var newVal = mView.cycleMinSpeedThreshold();
                item.setSubLabel(newVal.format("%.1f") + " m/s");
            } else if (id == :itemSetSweepSpd) {
                var newVal = mView.cycleSweepSpeedThreshold();
                item.setSubLabel(newVal.format("%.1f") + " m/s");
            } else if (id == :itemSetGeofence) {
                var newVal = mView.cycleGeofenceDistance();
                item.setSubLabel(newVal.format("%.0f") + " m");
            } else if (id == :itemSetCooldown) {
                var newVal = mView.cycleSweptCooldownDuration();
                item.setSubLabel(newVal.format("%d") + " s");
            } else if (id == :itemResetDef) {
                mView.resetThresholdDefaults();
                WatchUi.popView(WatchUi.SLIDE_IMMEDIATE);
                mView.showSettingsMenu();
            }
        }
    }
}
