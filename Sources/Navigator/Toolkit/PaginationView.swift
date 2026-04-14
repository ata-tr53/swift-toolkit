//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import ReadiumShared

#if os(macOS)
import AppKit
import QuartzCore
#else
import UIKit
#endif

enum PageLocation: Equatable {
    case start
    case end
    case locator(Locator)

    init(_ locator: Locator?) {
        self = locator.map { .locator($0) }
            ?? .start
    }

    var isStart: Bool {
        switch self {
        case .start:
            return true
        case let .locator(locator) where locator.locations.progression ?? 0 == 0:
            return true
        default:
            return false
        }
    }
}

protocol PageView {
    /// Moves the page to the given internal location.
    func go(to location: PageLocation, animated: Bool) async
}

// MARK: - Mac Implementation

#if os(macOS)

protocol PaginationViewDelegate: AnyObject {
    /// Creates the page view for the page at given index.
    func paginationView(_ paginationView: PaginationView, pageViewAtIndex index: Int) -> (NSView & PageView)?

    /// Called when the page views were updated.
    func paginationViewDidUpdateViews(_ paginationView: PaginationView)

    /// Returns the number of positions (as in `Publication.positionList`) in the page view at given index.
    func paginationView(_ paginationView: PaginationView, positionCountAtIndex index: Int) -> Int
}

final class PaginationView: NSView, Loggable {
    weak var delegate: PaginationViewDelegate?

    private(set) var pageCount: Int = 0
    private(set) var currentIndex: Int = 0
    private(set) var readingProgression: ReadingProgression = .ltr
    private(set) var loadedViews: [Int: NSView & PageView] = [:]

    private let preloadPreviousPositionCount: Int
    private let preloadNextPositionCount: Int
    private var loadingIndexQueue: [(index: Int, location: PageLocation)] = []

    var isEmpty: Bool { loadedViews.isEmpty }
    var currentView: (NSView & PageView)? { loadedViews[currentIndex] }
    
    // Ignored on macOS layout, but required by protocol/init
    var isScrollEnabled: Bool = false

    init(
        frame: CGRect,
        preloadPreviousPositionCount: Int,
        preloadNextPositionCount: Int,
        isScrollEnabled: Bool
    ) {
        self.preloadPreviousPositionCount = preloadPreviousPositionCount
        self.preloadNextPositionCount = preloadNextPositionCount
        self.isScrollEnabled = isScrollEnabled
        super.init(frame: frame)
        
        self.wantsLayer = true
        self.layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        currentView?.frame = bounds
    }

    override func viewWillMove(toSuperview newSuperview: NSView?) {
        super.viewWillMove(toSuperview: newSuperview)
        if newSuperview == nil {
            for (_, view) in loadedViews { view.removeFromSuperview() }
            loadedViews.removeAll()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            loadPagesTask?.cancel()
        } else {
            loadPages()
        }
    }

    func reloadAtIndex(_ index: Int, location: PageLocation, pageCount: Int, readingProgression: ReadingProgression) {
        precondition(pageCount >= 1)
        precondition(0 ..< pageCount ~= index)

        self.pageCount = pageCount
        self.readingProgression = readingProgression

        for (_, view) in loadedViews { view.removeFromSuperview() }
        loadedViews.removeAll()
        loadingIndexQueue.removeAll()

        setCurrentIndex(index, location: location)
    }

    private func setCurrentIndex(_ index: Int, location: PageLocation? = nil) {
        guard isEmpty || index != currentIndex else { return }

        let movingBackward = (currentIndex - 1 == index)
        let loc = location ?? (movingBackward ? .end : .start)

        currentIndex = index

        scheduleLoadPage(at: index, location: loc)
        let lastIndex = scheduleLoadPages(from: index, upToPositionCount: preloadNextPositionCount, direction: .forward, location: .start)
        let firstIndex = scheduleLoadPages(from: index, upToPositionCount: preloadPreviousPositionCount, direction: .backward, location: .end)

        for (i, view) in loadedViews {
            guard firstIndex ... lastIndex ~= i else {
                view.removeFromSuperview()
                loadedViews.removeValue(forKey: i)
                continue
            }
        }
        
        // Immediately swap the current view into the hierarchy on Mac
        if let newView = loadedViews[currentIndex] {
            for subview in subviews { subview.removeFromSuperview() }
            addSubview(newView)
            newView.frame = bounds
        }

        loadPages()
    }

    private func loadPages() {
        loadPagesTask = Task { @MainActor in
            await loadNextPage()
            delegate?.paginationViewDidUpdateViews(self)
        }
    }

    private var loadPagesTask: Task<Void, Never>?

    private func loadNextPage() async {
        guard let (index, location) = loadingIndexQueue.popFirst() else { return }

        if loadedViews[index] == nil, let view = delegate?.paginationView(self, pageViewAtIndex: index) {
            loadedViews[index] = view
            
            // Only add to subviews if it's the actively visible page
            if index == currentIndex {
                for subview in subviews { subview.removeFromSuperview() }
                addSubview(view)
                needsLayout = true
            }
        }

        if let view = loadedViews[index] {
            await view.go(to: location, animated: false)
        }
        await loadNextPage()
    }

    private func scheduleLoadPages(from sourceIndex: Int, upToPositionCount positionCount: Int, direction: PageIndexDirection, location: PageLocation) -> Int {
        let index = sourceIndex + direction.rawValue
        guard positionCount > 0, scheduleLoadPage(at: index, location: location),
              let indexPositionCount = delegate?.paginationView(self, positionCountAtIndex: index) else {
            return sourceIndex
        }

        return scheduleLoadPages(
            from: index, upToPositionCount: positionCount - indexPositionCount,
            direction: direction, location: location
        )
    }

    @discardableResult
    private func scheduleLoadPage(at index: Int, location: PageLocation) -> Bool {
        guard 0 ..< pageCount ~= index else { return false }
        loadingIndexQueue.removeAll { $0.index == index }
        loadingIndexQueue.append((index: index, location: location))
        return true
    }

    private enum PageIndexDirection: Int {
        case forward = 1
        case backward = -1
    }

    func goToIndex(_ index: Int, location: PageLocation, options: NavigatorGoOptions) async -> Bool {
        guard 0 ..< pageCount ~= index else { return false }

        let shouldAnimate = options.animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        if currentIndex == index {
            await currentView?.go(to: location, animated: shouldAnimate)
        } else {
            if shouldAnimate {
                let transition = CATransition()
                transition.duration = 0.25
                
                if abs(currentIndex - index) == 1 {
                    transition.type = .push
                    let movingForward = index > currentIndex
                    let rightToLeft = readingProgression == .rtl
                    if movingForward {
                        transition.subtype = rightToLeft ? .fromLeft : .fromRight
                    } else {
                        transition.subtype = rightToLeft ? .fromRight : .fromLeft
                    }
                } else {
                    transition.type = .fade
                }
                
                self.layer?.add(transition, forKey: "macPageTransition")
            }
            setCurrentIndex(index, location: location)
        }
        return true
    }
}

// MARK: - iOS Implementation

#else

protocol PaginationViewDelegate: AnyObject {
    /// Creates the page view for the page at given index.
    func paginationView(_ paginationView: PaginationView, pageViewAtIndex index: Int) -> (UIView & PageView)?

    /// Called when the page views were updated.
    func paginationViewDidUpdateViews(_ paginationView: PaginationView)

    /// Returns the number of positions (as in `Publication.positionList`) in the page view at given index.
    func paginationView(_ paginationView: PaginationView, positionCountAtIndex index: Int) -> Int
}

final class PaginationView: UIView, Loggable {
    weak var delegate: PaginationViewDelegate?

    /// Total number of page views to be paginated.
    private(set) var pageCount: Int = 0

    /// Index of the page currently being displayed.
    private(set) var currentIndex: Int = 0

    /// Direction for the reading progression.
    private(set) var readingProgression: ReadingProgression = .ltr

    /// Pre-loaded page views, indexed by their position.
    private(set) var loadedViews: [Int: UIView & PageView] = [:]

    /// Number of positions (as in `Publication.positionList`) to preload before and after the
    /// current page.
    private let preloadPreviousPositionCount: Int
    private let preloadNextPositionCount: Int

    /// Queue of page index to be loaded next.
    private var loadingIndexQueue: [(index: Int, location: PageLocation)] = []

    /// Returns whether the page views are loaded.
    var isEmpty: Bool {
        loadedViews.isEmpty
    }

    /// Return the currently presented page view from the Views array.
    var currentView: (UIView & PageView)? {
        loadedViews[currentIndex]
    }

    /// Loaded page views in reading order.
    private var orderedViews: [UIView & PageView] {
        var orderedViews = loadedViews
            .sorted { $0.key < $1.key }
            .map(\.value)

        if readingProgression == .rtl {
            orderedViews.reverse()
        }

        return orderedViews
    }

    private let scrollView = UIScrollView()

    /// Set while a transition animation is in progress to prevent
    /// `layoutSubviews` from resetting `contentOffset` and interrupting the
    /// animation.
    private var isAnimatingContentOffset = false

    /// Allows the scroll view to scroll.
    var isScrollEnabled: Bool {
        didSet { scrollView.isScrollEnabled = isScrollEnabled }
    }

    init(
        frame: CGRect,
        preloadPreviousPositionCount: Int,
        preloadNextPositionCount: Int,
        isScrollEnabled: Bool
    ) {
        self.preloadPreviousPositionCount = preloadPreviousPositionCount
        self.preloadNextPositionCount = preloadNextPositionCount
        self.isScrollEnabled = isScrollEnabled

        super.init(frame: frame)

        scrollView.delegate = self
        scrollView.frame = bounds
        scrollView.autoresizingMask = [.flexibleHeight, .flexibleWidth]
        scrollView.isPagingEnabled = true
        scrollView.bounces = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.isScrollEnabled = isScrollEnabled
        addSubview(scrollView)

        insertSubview(UIView(frame: .zero), at: 0)
        scrollView.contentInsetAdjustmentBehavior = .never
    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        guard !loadedViews.isEmpty else {
            scrollView.contentSize = bounds.size
            return
        }

        let size = scrollView.bounds.size
        scrollView.contentSize = CGSize(width: size.width * CGFloat(pageCount), height: size.height)

        for (index, view) in loadedViews {
            view.frame = CGRect(origin: CGPoint(x: xOffsetForIndex(index), y: 0), size: size)
        }

        if !isAnimatingContentOffset {
            scrollView.contentOffset.x = xOffsetForIndex(currentIndex)
        }
    }

    override func willMove(toSuperview newSuperview: UIView?) {
        super.willMove(toSuperview: newSuperview)

        if newSuperview == nil {
            for (_, view) in loadedViews {
                view.removeFromSuperview()
            }
            loadedViews.removeAll()
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()

        if window == nil {
            loadPagesTask?.cancel()
        } else {
            loadPages()
        }
    }

    private func xOffsetForIndex(_ index: Int) -> CGFloat {
        (readingProgression == .rtl)
            ? scrollView.contentSize.width - (CGFloat(index + 1) * scrollView.bounds.width)
            : scrollView.bounds.width * CGFloat(index)
    }

    func reloadAtIndex(_ index: Int, location: PageLocation, pageCount: Int, readingProgression: ReadingProgression) {
        precondition(pageCount >= 1)
        precondition(0 ..< pageCount ~= index)

        self.pageCount = pageCount
        self.readingProgression = readingProgression

        for (_, view) in loadedViews {
            view.removeFromSuperview()
        }
        loadedViews.removeAll()
        loadingIndexQueue.removeAll()

        setCurrentIndex(index, location: location)
    }

    private func setCurrentIndex(_ index: Int, location: PageLocation? = nil) {
        guard isEmpty || index != currentIndex else {
            return
        }

        let movingBackward = (currentIndex - 1 == index)
        let location = location ?? (movingBackward ? .end : .start)

        currentIndex = index

        scheduleLoadPage(at: index, location: location)
        let lastIndex = scheduleLoadPages(from: index, upToPositionCount: preloadNextPositionCount, direction: .forward, location: .start)
        let firstIndex = scheduleLoadPages(from: index, upToPositionCount: preloadPreviousPositionCount, direction: .backward, location: .end)

        for (i, view) in loadedViews {
            guard firstIndex ... lastIndex ~= i else {
                view.removeFromSuperview()
                loadedViews.removeValue(forKey: i)
                continue
            }
        }

        loadPages()
    }

    private func loadPages() {
        // Preserving original Readium Task replacement syntax
        loadPagesTask?.cancel()
        loadPagesTask = Task { @MainActor in
            await loadNextPage()
            delegate?.paginationViewDidUpdateViews(self)
        }
    }

    private var loadPagesTask: Task<Void, Never>?

    private func loadNextPage() async {
        guard let (index, location) = loadingIndexQueue.popFirst() else {
            return
        }

        if
            loadedViews[index] == nil,
            let view = delegate?.paginationView(self, pageViewAtIndex: index)
        {
            loadedViews[index] = view
            scrollView.addSubview(view)
            setNeedsLayout()
        }

        guard let view = loadedViews[index] else {
            return
        }

        await view.go(to: location, animated: false)
        await loadNextPage()
    }

    private func scheduleLoadPages(from sourceIndex: Int, upToPositionCount positionCount: Int, direction: PageIndexDirection, location: PageLocation) -> Int {
        let index = sourceIndex + direction.rawValue
        guard
            positionCount > 0,
            scheduleLoadPage(at: index, location: location),
            let indexPositionCount = delegate?.paginationView(self, positionCountAtIndex: index)
        else {
            return sourceIndex
        }

        return scheduleLoadPages(
            from: index,
            upToPositionCount: positionCount - indexPositionCount,
            direction: direction,
            location: location
        )
    }

    @discardableResult
    private func scheduleLoadPage(at index: Int, location: PageLocation) -> Bool {
        guard 0 ..< pageCount ~= index else {
            return false
        }

        loadingIndexQueue.removeAll { $0.index == index }
        loadingIndexQueue.append((index: index, location: location))
        return true
    }

    private enum PageIndexDirection: Int {
        case forward = 1
        case backward = -1
    }

    // MARK: - Navigation

    func goToIndex(_ index: Int, location: PageLocation, options: NavigatorGoOptions) async -> Bool {
        guard 0 ..< pageCount ~= index else {
            return false
        }

        let shouldAnimate = options.animated && !UIAccessibility.isReduceMotionEnabled

        if currentIndex == index {
            await scrollToView(at: index, location: location, animated: shouldAnimate)
        } else if abs(currentIndex - index) == 1 {
            await slideToView(at: index, location: location, animated: shouldAnimate)
        } else {
            await fadeToView(at: index, location: location, animated: shouldAnimate)
        }
        return true
    }

    private func slideToView(at index: Int, location: PageLocation, animated: Bool) async {
        let fromOffset = scrollView.contentOffset
        let targetOffset = CGPoint(x: xOffsetForIndex(index), y: fromOffset.y)
        let translationX = fromOffset.x - targetOffset.x

        let snapshot = snapshotView(afterScreenUpdates: false)
        if let snapshot {
            snapshot.frame = bounds
            addSubview(snapshot)
        } else {
            log(.warning, "Could not take a snapshot before sliding to view at index \(index); page transition may flash")
        }

        isAnimatingContentOffset = true
        scrollView.isScrollEnabled = false

        defer {
            snapshot?.removeFromSuperview()
            isAnimatingContentOffset = false
            scrollView.isScrollEnabled = isScrollEnabled
        }

        setCurrentIndex(index, location: location)

        scrollView.contentOffset = fromOffset

        if animated {
            await animate(duration: 0.3) {
                snapshot?.transform = CGAffineTransform(translationX: translationX, y: 0)
                self.scrollView.contentOffset = targetOffset
            }
        } else {
            scrollView.contentOffset = targetOffset
        }

        if !animated {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func fadeToView(at index: Int, location: PageLocation, animated: Bool) async {
        func fade(to alpha: CGFloat) async {
            await animate(duration: animated ? 0.15 : 0) {
                self.alpha = alpha
            }
        }

        await fade(to: 0)
        await scrollToView(at: index, location: location, animated: false)
        await fade(to: 1)
    }

    private func scrollToView(at index: Int, location: PageLocation, animated: Bool) async {
        guard currentIndex != index else {
            if let view = currentView {
                await view.go(to: location, animated: animated)
            }
            return
        }

        scrollView.isScrollEnabled = isScrollEnabled
        setCurrentIndex(index, location: location)

        scrollView.scrollRectToVisible(CGRect(
            origin: CGPoint(
                x: xOffsetForIndex(index),
                y: scrollView.contentOffset.y
            ),
            size: scrollView.frame.size
        ), animated: animated)
    }

    private func animate(duration: TimeInterval, animations: @escaping () -> Void) async {
        if duration > 0 {
            await withCheckedContinuation { continuation in
                UIView.animate(
                    withDuration: duration,
                    animations: animations,
                    completion: { _ in
                        continuation.resume()
                    }
                )
            }
        } else {
            animations()
        }
    }
}

extension PaginationView: UIScrollViewDelegate {
    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        scrollView.isScrollEnabled = false
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        scrollView.isScrollEnabled = isScrollEnabled
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            scrollView.isScrollEnabled = isScrollEnabled
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        guard !isAnimatingContentOffset else { return }

        scrollView.isScrollEnabled = isScrollEnabled

        let currentOffset = (readingProgression == .rtl)
            ? scrollView.contentSize.width - (scrollView.contentOffset.x + scrollView.frame.width)
            : scrollView.contentOffset.x

        let newIndex = Int(round(currentOffset / scrollView.frame.width))
        setCurrentIndex(newIndex)
    }
}
#endif
