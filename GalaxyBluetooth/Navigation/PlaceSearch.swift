import SwiftUI
import MapKit

enum PlaceSearchPurpose: String, Identifiable {
    case destination, start, home, work, favorite
    var id: String { rawValue }
    var savedKind: SavedPlaceKind? {
        switch self {
        case .destination, .start: nil
        case .home: .home
        case .work: .work
        case .favorite: .favorite
        }
    }
}

struct PlaceSearch: View {
    @ObservedObject var navigation: NavigationModel
    @ObservedObject var saved: SavedPlacesStore
    let saveAs: SavedPlaceKind?
    var choosingStart = false
    let onSelect: (NavigationPlace) -> Void
    @State private var query = ""
    @State private var searchPresented = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        if !saved.recentDestinations.isEmpty {
                            HStack {
                                Text("Recent Destinations").font(.headline)
                                Spacer()
                                Menu {
                                    Button("Clear Recent Destinations", role: .destructive) { saved.clearRecentDestinations() }
                                } label: {
                                    Image(systemName: "ellipsis.circle").frame(width: 44, height: 44)
                                }.accessibilityLabel("Recent destination options")
                            }
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 10)], spacing: 10) {
                                ForEach(saved.recentDestinations) { place in
                                    Button { onSelect(saved.navigationPlace(place)); dismiss() } label: {
                                        VStack(alignment: .leading, spacing: 6) {
                                            Image(systemName: "clock.arrow.circlepath").accessibilityHidden(true).foregroundStyle(StarPilotTheme.accent)
                                            Text(place.name).font(.headline).lineLimit(2)
                                            Text(place.address).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                        }
                                        .padding(12).frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
                                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
                                    }.buttonStyle(.plain)
                                }
                            }
                        } else {
                            ContentUnavailableView("Find a place", systemImage: "magnifyingglass",
                                                   description: Text("Search by name or address."))
                        }
                    } else {
                        ForEach(navigation.suggestions, id: \.self) { suggestion in
                            Button {
                                Task {
                                    if let place = await navigation.resolve(suggestion) { onSelect(place); dismiss() }
                                }
                            } label: { resultLabel(suggestion.title, address: suggestion.subtitle) }
                            .disabled(navigation.searching)
                            .accessibilityIdentifier("place-search-result")
                        }
                        ForEach(navigation.results) { place in
                            Button { onSelect(place); dismiss() } label: { resultLabel(place.name, address: place.address) }
                                .accessibilityIdentifier("place-search-result")
                        }
                    }
                    if navigation.searching { ProgressView("Searching…").padding(.vertical, 8) }
                    if !navigation.searchMessage.isEmpty { Text(LocalizedStringKey(navigation.searchMessage)).foregroundStyle(.secondary) }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16).padding(.bottom, 16)
            }
            .navigationTitle(choosingStart ? "Starting point" : saveAs == .home ? "Add Home" : saveAs == .work ? "Add Work" : saveAs == .favorite ? "Add Favorite" : "Search Maps")
            .searchable(text: $query, isPresented: $searchPresented, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search places or addresses")
            .onAppear { searchPresented = true }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onChange(of: query, initial: true) { _, text in navigation.suggest(text, choosingStart: choosingStart) }
            .onDisappear { navigation.cancelPlaceSearch() }
        }.presentationDetents([.medium, .large])
    }

    private func resultLabel(_ title: String, address: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "mappin").foregroundStyle(StarPilotTheme.accent)
                .frame(width: 36, height: 36).background(StarPilotTheme.accent.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                if !address.isEmpty { Text(address).font(.subheadline).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
        }
        .padding(12).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .contentShape(Rectangle())
    }

}

struct SavedPlacesView: View {
    @ObservedObject var saved: SavedPlacesStore
    let onSelect: (SavedPlace) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var renaming: SavedPlace?
    @State private var name = ""
    @State private var showRename = false
    var body: some View {
        NavigationStack {
            List {
                ForEach(SavedPlaceKind.allCases, id: \.self) { kind in
                    Section(kind == .home ? "Home" : kind == .work ? "Work" : "Favorites") {
                        ForEach(saved.library.places.filter { $0.kind == kind }) { place in
                            Button { onSelect(place); dismiss() } label: {
                                Label {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(place.name).foregroundStyle(.primary)
                                        Text(place.address).font(.caption).foregroundStyle(.secondary)
                                    }
                                } icon: {
                                    Image(systemName: kind == .home ? "house.fill" : kind == .work ? "briefcase.fill" : "star.fill")
                                        .foregroundStyle(StarPilotTheme.accent)
                                }.padding(.vertical, 4)
                            }
                            .swipeActions {
                                Button("Delete", role: .destructive) { saved.remove(place) }
                                Button("Rename") { renaming = place; name = place.name; showRename = true }.tint(StarPilotTheme.accent)
                            }
                        }
                    }
                }
                Section { Text("Saved on this iPhone.").font(.caption).foregroundStyle(.secondary) }
                if !saved.message.isEmpty { Text(LocalizedStringKey(saved.message)).font(.caption) }
            }
            .navigationTitle("Saved Places")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .alert("Rename place", isPresented: $showRename) {
                TextField("Name", text: $name)
                Button("Save") { if let place = renaming { saved.rename(place, to: name) } }
                Button("Cancel", role: .cancel) {}
            }
        }
    }
}

struct RecentDestinationRow: View {
    let place: SavedPlace
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: "clock").accessibilityHidden(true).font(.title3).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(place.name).font(.headline).foregroundStyle(.primary).lineLimit(1)
                    Text(place.address).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }.padding(.vertical, 6).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}
