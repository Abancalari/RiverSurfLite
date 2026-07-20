import Toybox.Application;
import Toybox.WatchUi;

class RiverSurfApp extends Application.AppBase {

    function initialize() {
        AppBase.initialize();
    }

    function onStart(state) {
    }

    function onStop(state) {
    }

    function getInitialView() {
        var view = new RiverSurfView();
        var delegate = new RiverSurfDelegate(view);
        return [ view, delegate ];
    }

}

function getApp() {
    return Application.getApp();
}
