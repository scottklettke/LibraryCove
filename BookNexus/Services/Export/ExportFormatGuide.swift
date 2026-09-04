import Foundation

extension LibraryDataService {

    /// The step-by-step format guide shipped inside every export archive and
    /// mirrored in the repository's `EXPORT-FORMAT.md`.
    static let formatGuide = """
    # BookNexus Library Format

    BookNexus exports your whole library as a single compressed (`.zip`) file. Inside it you
    will find:

    - `library.json` - your complete library in plain, human-readable JSON.
    - `covers/` - one JPEG file per book cover.
    - `README-FORMAT.md` - this guide.

    The data is meant to be read, reviewed, and even edited by hand. You can add new books by
    adding new objects to the `books` array, re-zip the folder, and import it back into the app.

    BookNexus is open source. The same format is used by every BookNexus installation, so a
    file you create by hand today can be imported into any BookNexus app, on any device.

    ----

    ## 1. What is inside the archive

    The archive contains:

    | File / directory | Purpose |
    |---|---|
    | `library.json` | All of your data (users, books, notes, reading lists, connections). |
    | `covers/` | One JPEG per book cover, named `<book id>.jpg`. |
    | `README-FORMAT.md` | This guide. |

    ### Covers

    Covers are separate files, not base64 blobs in the JSON. Each book whose cover
    was available at export time has an entry `covers/<book id>.jpg` and its
    `coverImageFile` field points at that entry. On import these JPEGs are written
    back to the device and `coverImageURL` is set to the local file, so restored
    covers render offline. `coverImageFile` is optional: a book without a bundled
    cover (or a hand-made file) keeps whatever `coverImageURL` says.

    ## 2. The top level of library.json

    `library.json` is a single JSON object with seven keys:

    ```json
    {
      "format": "booknexus-library",
      "version": 1,
      "exportedAt": "2026-08-12T12:34:56Z",
      "users": [],
      "books": [],
      "notes": [],
      "readingLists": [],
      "readingListItems": [],
      "connections": []
    }
    ```

    - `format` and `version` identify the file format. Do not change `format`; keep `version` at 1.
    - `exportedAt` is the moment the file was written (ISO 8601, UTC).
    - The six remaining keys are arrays. An empty library simply has empty arrays.

    ## 3. Common rules

    - **IDs** are UUID strings, e.g. `"9F8E4B3A-2C1D-4E5F-8A7B-0C9D1E2F3A4B"`. Every object needs a
      unique one. You can generate one at <https://www.uuidgenerator.net> or with any `uuidgen`.
    - **Dates** are ISO 8601 with a time zone, e.g. `"2026-08-12T12:34:56Z"`. Write them in UTC
      (ends in `Z`) to be safe.
    - **Optional fields** are either a value or `null`. If a field is optional you may leave it
      out entirely; missing optional fields are treated as `null`.
    - **List fields** (`authors`, `tags`, `mentions`) are arrays of strings.
    - **Relationships** (which book a note belongs to, which books a connection links, etc.) are
      stored as the *id* of the related object. Those ids must match the `id` of an object that
      actually exists in the file. A relationship can be `null`.

    ## 4. Books  (the object you will edit most)

    A book object looks like this:

    ```json
    {
      "id": "11111111-1111-1111-1111-111111111111",
      "title": "Dune",
      "authors": ["Frank Herbert"],
      "isbn": "9780441172719",
      "publicationYear": 1965,
      "tags": ["Science Fiction"],
      "coverImageURL": null,
      "publisher": "Ace Books",
      "pageCount": 412,
      "bookDescription": "A desert planet. Spice. Destiny.",
      "descriptionSource": "openlibrary",
      "language": "en",
      "physicalLocation": "Shelf C",
      "status": "reading",
      "acquiredDate": null,
      "purchasePrice": null,
      "rating": 5,
      "loanedTo": null,
      "loanedDate": null,
      "ownerID": null,
      "sharedLibraryID": null,
      "isPersonal": true,
      "createdAt": "2026-08-12T12:34:56Z",
      "updatedAt": "2026-08-12T12:34:56Z",
      "syncState": "modified",
      "syncUpdatedAt": "2026-08-12T12:34:56Z",
      "syncDeviceID": ""
    }
    ```

    Field reference:

    | Field | Type | Meaning |
    |---|---|---|
    | `id` | string | Unique identifier (required). |
    | `title` | string | Book title (required). |
    | `authors` | array of string | Author names. |
    | `isbn` | string / null | ISBN-10 or ISBN-13. |
    | `publicationYear` | integer / null | Year of publication. |
    | `tags` | array of string | Genres or categories. |
    | `coverImageFile` | string / null | Relative zip entry (`covers/<book id>.jpg`) that carries the cover's JPEG bytes. Set only by exports with an available cover. |
    | `coverImageURL` | string / null | URL of a cover, or local file path after an import. Cleared when a bundled `coverImageFile` takes over. |
    | `publisher` | string / null | Publisher name. |
    | `pageCount` | integer / null | Number of pages. |
    | `bookDescription` | string / null | Short summary or description. |
    | `descriptionSource` | string / null | Where the description came from (`openlibrary`, `googlebooks`, `wikipedia`, `none`). |
    | `language` | string / null | Language code, e.g. `en`. |
    | `physicalLocation` | string / null | Where the physical book lives, e.g. `Shelf C`. |
    | `status` | string | One of `to-read`, `reading`, `completed`, `donated`. |
    | `acquiredDate` | date / null | When it was acquired. |
    | `purchasePrice` | number / null | Price paid. |
    | `rating` | integer / null | 1 to 5 stars, or `null` for unrated. |
    | `loanedTo` | string / null | Person it is currently loaned to. |
    | `loanedDate` | date / null | When it was loaned out. |
    | `ownerID` | string / null | Owner family member id. |
    | `sharedLibraryID` | string / null | Future shared-library id. |
    | `isPersonal` | boolean | Usually `true`. |
    | `createdAt` / `updatedAt` | date | Timestamps (required). |
    | `syncState` | string | `synced`, `modified`, or `deleted`. New entries: `modified`. |
    | `syncUpdatedAt` | date | Sync timestamp. |
    | `syncDeviceID` | string | Device that wrote it. Leave `""` for hand-made files. |

    ### How to add a new book, step by step

    1. Export your library from BookNexus (Settings -> Data -> Export library) and unzip the file.
    2. Open `library.json` in any text or JSON editor (VS Code, TextEdit, etc.).
    3. Find the `"books"` array near the top: `"books": [`.
    4. Copy an existing book object (everything from `{` to the matching `}`), including its
       trailing comma if it was not the last element.
    5. Paste a duplicate below the last book (add a trailing comma to the previous last book if
       needed).
    6. Change the duplicated fields to your new book. Give it a brand new `id`; a fresh UUID is
       required so it never collides with another book. Set `title`, `authors`, and anything else
       you want.
    7. Update `createdAt` and `updatedAt` to the current timestamp so the new book sorts
       correctly by "date added".
    8. Save the file. The JSON must stay valid: every `{` needs a `}`, every array needs a
       closing `]`, and the last element in each array has no trailing comma.
    9. Zip the folder again (on macOS: right-click the folder -> Compress; on Windows: right-click
       -> Send to -> Compressed folder). The zip must contain `library.json` at its top level,
       with any cover JPEGs in a `covers/` folder alongside it.
    10. Open BookNexus, go to Settings -> Data -> Import library, and choose the zip. The app will
        show you how many books it found and replace your library with the file's contents.

    ## 5. Users  (family members)

    ```json
    {
      "id": "22222222-2222-2222-2222-222222222222",
      "email": "you@example.com",
      "displayName": "You",
      "avatarURL": null,
      "timezone": "UTC",
      "language": "en",
      "isActive": true,
      "createdAt": "2026-08-12T12:34:56Z",
      "lastLoginAt": null
    }
    ```

    Field reference:

    | Field | Type | Meaning |
    |---|---|---|
    | `id` | string | Unique identifier (required). |
    | `email` | string | Email address (required). |
    | `displayName` | string | Name shown in the app (required). |
    | `avatarURL` | string / null | Profile image URL. |
    | `timezone` | string | Time zone, e.g. `UTC`. |
    | `language` | string | Language code, e.g. `en`. |
    | `isActive` | boolean | Whether this is the active member. At least one user should be active or the app shows the login screen. |
    | `createdAt` | date | Created timestamp. |
    | `lastLoginAt` | date / null | Last login timestamp. |

    ## 6. Notes

    ```json
    {
      "id": "33333333-3333-3333-3333-333333333333",
      "bookID": "11111111-1111-1111-1111-111111111111",
      "userID": "22222222-2222-2222-2222-222222222222",
      "title": "First impressions",
      "content": "The world-building is extraordinary.",
      "noteType": "general",
      "visibility": "private",
      "sharedLibraryID": null,
      "pageReference": "p. 12",
      "mentions": [],
      "createdAt": "2026-08-12T12:34:56Z",
      "updatedAt": "2026-08-12T12:34:56Z",
      "syncState": "modified",
      "syncUpdatedAt": "2026-08-12T12:34:56Z",
      "syncDeviceID": ""
    }
    ```

    | Field | Type | Meaning |
    |---|---|---|
    | `id` | string | Unique identifier. |
    | `bookID` | string / null | The `id` of the book this note belongs to, or `null` for a general note. |
    | `userID` | string | The `id` of the member who wrote it. |
    | `title` | string / null | Optional note title. |
    | `content` | string | The note text (required). |
    | `noteType` | string | One of `general`, `takeaway`, `quote`, `question`, `connection`. |
    | `visibility` | string | One of `private`, `shared`, `public`. |
    | `sharedLibraryID` | string / null | Future shared-library id. |
    | `pageReference` | string / null | Page or location reference. |
    | `mentions` | array of string | Mentioned book/user ids. |
    | `createdAt` / `updatedAt` | date | Timestamps. |
    | `syncState` / `syncUpdatedAt` / `syncDeviceID` | - | Sync metadata; `syncDeviceID` can be `""`. |

    ## 7. Reading lists and list items

    A reading list:

    ```json
    {
      "id": "44444444-4444-4444-4444-444444444444",
      "name": "Summer 2026",
      "listDescription": "Books to read on vacation.",
      "ownerID": "22222222-2222-2222-2222-222222222222",
      "sharedLibraryID": null,
      "isPrivate": true,
      "createdAt": "2026-08-12T12:34:56Z",
      "updatedAt": "2026-08-12T12:34:56Z",
      "syncState": "modified",
      "syncUpdatedAt": "2026-08-12T12:34:56Z",
      "syncDeviceID": ""
    }
    ```

    A list item (one entry in a list, pointing at a book):

    ```json
    {
      "id": "55555555-5555-5555-5555-555555555555",
      "listID": "44444444-4444-4444-4444-444444444444",
      "bookID": "11111111-1111-1111-1111-111111111111",
      "addedByID": "22222222-2222-2222-2222-222222222222",
      "position": 0,
      "priority": "normal",
      "targetDate": null,
      "createdAt": "2026-08-12T12:34:56Z",
      "syncState": "modified",
      "syncUpdatedAt": "2026-08-12T12:34:56Z",
      "syncDeviceID": ""
    }
    ```

    - `listID` is the `id` of a reading list; `bookID` is the `id` of the book in the list.
      Both must exist in the file.
    - `position` is the order within the list (0 is first).
    - `priority` is one of `low`, `normal`, `high`.

    ## 8. Connections

    A connection links two books:

    ```json
    {
      "id": "66666666-6666-6666-6666-666666666666",
      "book1ID": "11111111-1111-1111-1111-111111111111",
      "book2ID": "99999999-9999-9999-9999-999999999999",
      "connectionType": "similar_to",
      "connectionDescription": "Both explore colonialism.",
      "createdByID": "22222222-2222-2222-2222-222222222222",
      "sharedLibraryID": null,
      "createdAt": "2026-08-12T12:34:56Z",
      "syncState": "modified",
      "syncUpdatedAt": "2026-08-12T12:34:56Z",
      "syncDeviceID": ""
    }
    ```

    - `book1ID` and `book2ID` are the ids of the two books being connected. They may be identical
      (a self-reference).
    - `connectionType` is one of `inspired_by`, `expands_on`, `contrasts_with`, `similar_to`.

    ## 9. Checking your file before importing

    - The file must be valid JSON. Paste it into a validator such as
      <https://jsonlint.com> to check.
    - Every id referenced by `bookID`, `listID`, `userID`, `book1ID`, `book2ID`, `ownerID`,
      `addedByID`, and `createdByID` must exist in the corresponding array.
    - The top-level `format` value must stay `"booknexus-library"` and `version` must stay `1`.
    - When re-zipping, make sure the zip contains `library.json` at its top level (not nested
      inside another folder).

    ## 10. Importing

    BookNexus imports a zip by *replacing* your current library with the contents of the file.
    Export your library first if you want a copy of the current state.

    1. Settings -> Data -> Import library.
    2. Pick the zip file.
    3. Review the counts BookNexus shows you.
    4. Confirm. Your library is replaced with the file's contents.
    """
}
