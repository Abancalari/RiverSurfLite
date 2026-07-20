import Toybox.WatchUi;
import Toybox.System;

class RiverSurfDelegate extends WatchUi.BehaviorDelegate {
    private var mView;

    function initialize(view) {
        BehaviorDelegate.initialize();
        mView = view;
    }

    function onSelect() {
        if (mView.isRecording()) {
            mView.toggleRecording(); // Pause
            showPauseMenu();
        } else {
            mView.toggleRecording(); // Start/Resume
        }
        return true;
    }

    function onBack() {
        if (mView.isRecording()) {
            // Prevent exiting when recording
            return true;
        }
        
        if (mView.hasSession()) {
            showPauseMenu();
            return true;
        }
        
        return false; // Exit app
    }

    function showPauseMenu() {
        var menu = new WatchUi.Menu();
        menu.setTitle("Session Menu");
        menu.addItem("Resume", :itemResume);
        menu.addItem("Save", :itemSave);
        menu.addItem("Discard", :itemDiscard);
        
        WatchUi.pushView(menu, new RiverSurfMenuDelegate(mView), WatchUi.SLIDE_IMMEDIATE);
    }
}

class RiverSurfMenuDelegate extends WatchUi.MenuInputDelegate {
    private var mView;

    function initialize(view) {
        MenuInputDelegate.initialize();
        mView = view;
    }

    function onMenuItem(item) {
        // Pop the menu first to return to main screen
        WatchUi.popView(WatchUi.SLIDE_IMMEDIATE);

        if (item == :itemResume) {
            mView.toggleRecording(); // resumes
        } else if (item == :itemSave) {
            mView.saveSession();
            WatchUi.popView(WatchUi.SLIDE_IMMEDIATE); // Exit app (pop main view)
        } else if (item == :itemDiscard) {
            var confirm = new WatchUi.Confirmation("Discard Session?");
            WatchUi.pushView(confirm, new RiverSurfDiscardConfirmDelegate(mView), WatchUi.SLIDE_IMMEDIATE);
        }
    }
}

class RiverSurfDiscardConfirmDelegate extends WatchUi.ConfirmationDelegate {
    private var mView;

    function initialize(view) {
        ConfirmationDelegate.initialize();
        mView = view;
    }

    function onResponse(value) {
        if (value == WatchUi.CONFIRM_YES) {
            mView.discardSession();
            // Pop the main view to exit the app
            WatchUi.popView(WatchUi.SLIDE_IMMEDIATE);
        }
        return true;
    }
}
