module main

import vweb
import db.sqlite
import math

struct App {
	vweb.Context
mut:
	db sqlite.DB
}

struct Product {
	id int
mut:
	quantity     int
	name         string
	description  string
	price        f64
	price_break  int
	break_amount int
}

fn main() {
	mut app := App{
		db: sqlite.connect('coffee.db') or { panic(err) }
	}

	app.db.exec('CREATE TABLE IF NOT EXISTS banner(
					id INTEGER PRIMARY KEY,
					date TEXT NOT NULL,
					message TEST NOT NULL
 				)') or {
		panic(err)
	}

	app.db.exec('CREATE TABLE IF NOT EXISTS products(
					id INTEGER PRIMARY KEY,
					quantity INTEGER,
					name TEXT NOT NULL,
					description TEXT NOT NULL,
					price REAL NOT NULL,
					price_break INTEGER NOT NULL,
					break_amount REAL NOT NULL
				)') or {
		panic(err)
	}

	app.db.exec('INSERT INTO banner (date, message) VALUES ("Aug 27", "Now roasting Brazil Cerado!")') or {
		panic(err)
	}
	app.db.exec('INSERT INTO products (quantity,  name, description, price, price_break, break_amount) VALUES
					("22", "Regular Blend", "Our most loved blend of coffee. Featuring coffees from South America and Northern Africa", "11.00", "4", "1")') or {
		panic(err)
	}

	app.serve_static('/output.css', 'output.css')
	app.serve_static('/favicon.ico', 'favicon.ico')
	app.serve_static('/htmx.min.js', 'htmx.min.js')

	vweb.run(app, 8088)
}

['/']
pub fn (app &App) index() vweb.Result {
	banner := app.get_banner()
	return $vweb.html()
}

['/shop']
pub fn (mut app App) shop() vweb.Result {
	mut products := app.get_products() or { []Product{} }
	for i, product in products {
		products[i].quantity = math.min(4, product.quantity)
	}
	return $vweb.html()
}

['/price_per']
pub fn (mut app App) price_per() vweb.Result {
	// should probably take in the items id, to send less over the network
	println(app.query['id'])
	quantity := app.query['quantity'].int()
	id := app.query['id']
	row := app.db.exec_param('SELECT * FROM products WHERE id = ? LIMIT 1', id) or { panic(err) }
	if row.len == 0 {
		app.set_status(204, 'no product')
		return app.html('')
	}
	price := row[0].vals[4].f64()
	price_break := row[0].vals[5].int()
	break_amount := row[0].vals[6].int()
	mut result_price := price * quantity
	if quantity >= price_break {
		result_price -= break_amount * quantity
	}
	return app.text('
<span id="price" hx-swap-oob="true">${result_price:.2f}</span>')
}

fn (app &App) get_banner() string {
	row := app.db.exec_one('SELECT * FROM banner ORDER BY id DESC LIMIT 1') or { panic(err) }
	return '${row.vals[1]}: ${row.vals[2]}'
}

fn (app &App) get_products() ?[]Product {
	rows := app.db.exec('SELECT * FROM products') or { panic(err) }
	if rows.len == 0 {
		return none
	}
	mut products := []Product{}
	for row in rows {
		product := Product{
			id: row.vals[0].int()
			quantity: row.vals[1].int()
			name: row.vals[2]
			description: row.vals[3]
			price: row.vals[4].f64()
			price_break: row.vals[5].int()
			break_amount: row.vals[6].int()
		}
		products << product
	}

	return products
}
