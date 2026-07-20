import Toybox.WatchUi;
import Toybox.System;

class RiverSurfDelegate extends WatchUi.BehaviorDelegate {
    private var mView;

    function initialize(view) {
        BehaviorDelegate.initialize();
        mView = view;
    }

    // Start/Stop button
    function onSelect() {
        if (mView != null) {
            mView.toggleRecording();
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

    // Back button (Pause Menu)
    function onBack() {
        if (mView != null) {
            if (mView.isRecording() || mView.hasSession()) {
                mView.showPauseMenu();
                return true;
            }
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
        WatchUi.popView(WatchUi.SLIDE_IMMEDIATE);

        if (item == :itemResume) {
            if (mView != null) {
                mView.startSession();
            }
        } else if (item == :itemSave) {
            if (mView != null) {
                mView.saveSession();
            }
            WatchUi.popView(WatchUi.SLIDE_IMMEDIATE);
        } else if (item == :itemDiscard) {
            if (mView != null) {
                mView.discardSession();
            }
            WatchUi.popView(WatchUi.SLIDE_IMMEDIATE);
        }
    }
}
