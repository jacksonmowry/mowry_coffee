module main

import vweb
// import markdown

['/blog']
pub fn (mut app App) blog() vweb.Result {
	return $vweb.html()
}
