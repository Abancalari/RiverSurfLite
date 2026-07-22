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
            } else if (item == :itemDiag) {
                mView.showDiagnosticsView();
            } else if (item == :itemSave) {
                mView.saveSession();
            } else if (item == :itemDiscard) {
                mView.discardSession();
            }
        }
    }
}

class RiverSurfSettingsMenuDelegate extends WatchUi.MenuInputDelegate {
    private var mView;

    function initialize(view) {
        MenuInputDelegate.initialize();
        mView = view;
    }

    function onMenuItem(item) {
        if (mView != null) {
            if (item == :itemSetVar) {
                mView.cycleAccelVarThreshold();
            } else if (item == :itemSetMinSpd) {
                mView.cycleMinSpeedThreshold();
            } else if (item == :itemSetSweepSpd) {
                mView.cycleSweepSpeedThreshold();
            } else if (item == :itemResetDef) {
                mView.resetThresholdDefaults();
            }
        }
    }
}
