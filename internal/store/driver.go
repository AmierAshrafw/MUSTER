// Package store owns all SQLite state: schema, migrations, and every board
// transaction. The blank import registers the pure-Go driver under name "sqlite".
package store

import _ "modernc.org/sqlite"
