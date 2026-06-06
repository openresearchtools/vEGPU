import Foundation
import ServiceManagement

enum LoginItemService {
    static var openAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setOpenAtLogin(_ enabled: Bool) throws {
        if enabled {
            if SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            }
        } else if SMAppService.mainApp.status == .enabled {
            try SMAppService.mainApp.unregister()
        }
    }
}

