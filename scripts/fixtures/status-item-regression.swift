import AppKit

@main
struct StatusItemRegression {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let notifications = NotificationCenter()
        let external = CGRect(x: 0, y: 0, width: 3008, height: 1692)
        let laptop = CGRect(x: 0, y: 0, width: 1496, height: 967)
        var screens = [external]
        var configured = 0
        var state = "Aufnahme"
        let controller = StatusItemController(notifications: notifications, screens: { screens }, delay: 0.03) { item in
            configured += 1
            item.button?.title = "SP"
            item.button?.toolTip = state
            let menu = NSMenu()
            menu.addItem(withTitle: "Verlauf", action: nil, keyEquivalent: "")
            item.menu = menu
        }
        func check(_ condition: Bool, _ label: String) {
            precondition(condition, label)
            print("PASS \(label)")
        }
        func changed() {
            notifications.post(name: NSApplication.didChangeScreenParametersNotification, object: app)
        }
        func settle() { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.12)) }
        let original = controller.item!
        changed(); settle()
        check(controller.item === original && configured == 1, "Gleiche Bildschirmfläche behält das Symbol")

        screens = [laptop]
        changed(); changed(); changed()
        check(configured == 1, "Neubau wartet auf das Ende der Bildschirmmeldungen")
        settle()
        check(controller.item !== original && configured == 2, "Abgesteckter Monitor führt zu genau einem neuen Symbol")
        check(controller.item.menu?.items.first?.title == "Verlauf" && controller.item.button?.toolTip == state,
              "Neues Symbol behält Menü und aktuellen Zustand")

        let onLaptop = controller.item!
        screens = [external]; changed()
        screens = [laptop]; changed(); settle()
        check(controller.item === onLaptop && configured == 2, "Zurückgenommener Bildschirmwechsel verwirft den wartenden Neubau")

        screens = []; changed(); settle()
        check(configured == 2, "Ohne verfügbare Bildschirme kein Neubau")
        screens = [laptop]
        state = "Pause"
        controller.recreate()
        check(configured == 3 && controller.item !== onLaptop && controller.item.button?.toolTip == "Pause",
              "Erneutes Öffnen erneuert das Symbol mit aktuellem Zustand")

        screens = [external]; changed()
        controller.invalidate(); settle()
        changed(); settle()
        check(configured == 3, "Beenden storniert wartende und weitere Wiederherstellungen")
        check(NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmost, "Kein Fokuswechsel")
    }
}
