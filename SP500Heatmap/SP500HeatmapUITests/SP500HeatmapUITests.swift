//
//  SP500HeatmapUITests.swift
//  SP500HeatmapUITests
//
//  Created by Maxim Yaroshenko on 11/6/26.
//

import XCTest

final class SP500HeatmapUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testExample() throws {
        // UI tests must launch the application that they test.
        let app = XCUIApplication()
        app.launch()

        // Use XCTAssert and related functions to verify your tests produce the correct results.
    }

    @MainActor
    func testAppStoreScreenshots() throws {
        let app = XCUIApplication()
        app.launch()

        let outDir = "/tmp/appstore_screenshots"
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

        func snap(_ name: String) {
            let screenshot = XCUIScreen.main.screenshot()
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
        }

        func firstElement(startingWith prefix: String) -> XCUIElement {
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "label BEGINSWITH %@", prefix))
                .firstMatch
        }

        // 1. Sectors heatmap
        let itSector = firstElement(startingWith: "Information Technology")
        XCTAssertTrue(itSector.waitForExistence(timeout: 20))
        snap("01_sectors")
        itSector.tap()

        // 2. Subsectors heatmap
        let semis = firstElement(startingWith: "Semiconductors")
        XCTAssertTrue(semis.waitForExistence(timeout: 15))
        snap("02_subsectors")
        semis.tap()

        // 3. Companies heatmap
        let nvda = firstElement(startingWith: "NVDA")
        XCTAssertTrue(nvda.waitForExistence(timeout: 15))
        snap("03_companies")
        nvda.tap()

        // 4. Company detail
        sleep(2)
        snap("04_company_detail")
    }

    @MainActor
    func testAppStoreScreenshotAllStocks() throws {
        let app = XCUIApplication()
        app.launch()

        let outDir = "/tmp/appstore_screenshots"
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

        let title = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "S&P 500"))
            .firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 20))
        title.tap()

        let nvdaRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "NVDA"))
            .firstMatch
        XCTAssertTrue(nvdaRow.waitForExistence(timeout: 15))
        sleep(1)

        let screenshot = XCUIScreen.main.screenshot()
        try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: "\(outDir)/00_all_stocks.png"))
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
