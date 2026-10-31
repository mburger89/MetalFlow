import Foundation
import MetalFlowCore

/// Why the folder dialog was opened, and so what happens with the folder chosen.
public enum AddRepoPurpose: Equatable, Sendable {
    /// Just add it.
    case dashboard
    /// Add it, then select it in the launch form's repo field.
    case launchField
    /// Add it, then save the pending draft into `<it>/.flows`.
    case saveDestination
    /// Add it, then set that Repo node's Fixed path or Exposed default.
    case repoNode(NodeID)
}

extension AppModel {
    /// Opens the folder dialog for `purpose`. Ignored while one is up.
    public func requestAddRepo(_ purpose: AddRepoPurpose) {
        guard addRepoRequest == nil, addRepoClaim == nil else { return }
        addRepoRequest = purpose
    }

    /// The dialog's binding was written false. A choice calls `finishAddRepo` straight after, in the same call; a
    /// cancel calls nothing, so a purpose still unclaimed one hop later was cancelled.
    func addRepoDialogEnded() {
        guard let purpose = addRepoRequest else { return }
        addRepoRequest = nil
        addRepoClaim = purpose
        Task {
            guard let purpose = takeAddRepoPurpose() else { return }
            await finishAddRepo(nil, purpose: purpose)
        }
    }

    /// Takes the purpose of the dialog that just ended, once, synchronously.
    func takeAddRepoPurpose() -> AddRepoPurpose? {
        defer { addRepoClaim = nil; addRepoRequest = nil }
        return addRepoClaim ?? addRepoRequest
    }

    /// Called with the chosen folder; nil means cancelled. Adds it, then does the purpose's follow-up.
    public func finishAddRepo(_ folder: URL?) async {
        guard let purpose = takeAddRepoPurpose() else { return }
        await finishAddRepo(folder, purpose: purpose)
    }

    func finishAddRepo(_ folder: URL?, purpose: AddRepoPurpose) async {
        var added: URL?
        if let folder, await addRepo(path: folder.path) {
            added = folder.standardizedFileURL
        }
        switch purpose {
        case .dashboard:
            break
        case .launchField:
            guard let added else { break }
            // The dashboard's field or the Studio's row, whichever has a repo field on the current screen.
            if screen == .studio {
                studioValues["repo"] = added.path
            } else {
                launchForm.values["repo"] = added.path
            }
        case .saveDestination:
            chooseSaveDestination(added.map { .repo($0) })
        case .repoNode(let id):
            if let added, let draft { RepoFields.setPath(draft, id, added.path, coalescing: false) }
        }
    }
}
