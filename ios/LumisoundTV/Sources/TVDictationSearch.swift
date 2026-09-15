import SwiftUI
import UIKit

// MARK: - TVDictationSearch
//
// Search backed by UIKit's `UISearchController` so the tvOS system keyboard —
// and therefore **dictation** — is available.
//
// SwiftUI's `.searchable` cannot do this: Apple's own DTS guidance is that
// there is no supported way to add voice input to a `searchable` field, so the
// Search tab offered only the grid keyboard and every query had to be pecked
// out letter by letter with the remote. `UISearchController` presented inside a
// `UISearchContainerViewController` is the platform's own search surface and
// gets the microphone for free, along with the full-width keyboard layout and
// the standard results presentation tvOS users already know.
//
// The results are ordinary SwiftUI, hosted inside the search controller, so
// nothing about the existing grid had to be rewritten to adopt this.
struct TVDictationSearch<Results: View>: UIViewControllerRepresentable {
    @Binding var text: String
    var placeholder: String
    /// Called when the query changes (debounced by the caller if needed).
    var onChange: (String) -> Void
    @ViewBuilder var results: () -> Results

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UISearchContainerViewController {
        let hosting = UIHostingController(rootView: results())
        hosting.view.backgroundColor = .clear

        let search = UISearchController(searchResultsController: hosting)
        search.searchResultsUpdater = context.coordinator
        search.searchBar.placeholder = placeholder
        // Keep the results visible before anything is typed — tvOS guidance is
        // to show recent/initial content rather than an empty pane, and this
        // screen already renders its own empty state.
        search.obscuresBackgroundDuringPresentation = false
        context.coordinator.hosting = hosting

        return UISearchContainerViewController(searchController: search)
    }

    func updateUIViewController(_ controller: UISearchContainerViewController, context: Context) {
        context.coordinator.parent = self
        // Re-render the hosted SwiftUI results whenever the owning view updates
        // (new search results arriving, loading state changing, …).
        context.coordinator.hosting?.rootView = results()
    }

    final class Coordinator: NSObject, UISearchResultsUpdating {
        var parent: TVDictationSearch
        var hosting: UIHostingController<Results>?

        init(_ parent: TVDictationSearch) { self.parent = parent }

        func updateSearchResults(for searchController: UISearchController) {
            let value = searchController.searchBar.text ?? ""
            guard value != parent.text else { return }
            // Hop off the UIKit callback before touching SwiftUI state —
            // mutating an @Binding synchronously from here reenters layout.
            DispatchQueue.main.async { [parent] in
                parent.text = value
                parent.onChange(value)
            }
        }
    }
}
