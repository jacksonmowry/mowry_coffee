module main

import vweb
import db.sqlite
import math
import rand

struct App {
	vweb.Context
mut:
	db   sqlite.DB
	cart Cart
}

struct Product {
	id int
mut:
	img          string
	q_on_hand    int
	name         string
	description  string
	price        f64
	price_break  int
	break_amount int
}

struct Cart_Product {
	product    Product
	quantity   int
	cart_index int
}

struct Cart {
	items []Cart_Product
mut:
	cart_id string
}

fn main() {
	mut app := App{
		db: sqlite.connect('coffee.db') or { panic(err) }
	}

	app.db.exec('CREATE TABLE IF NOT EXISTS banner(
					id INTEGER PRIMARY KEY,
					date TEXT NOT NULL,
					message TEST NOT NULL
 				)')!

	app.db.exec('CREATE TABLE IF NOT EXISTS products(
					id INTEGER PRIMARY KEY,
					img TEXT NOT NULL,
					q_on_hand INTEGER,
					name TEXT NOT NULL UNIQUE,
					description TEXT NOT NULL,
					price REAL NOT NULL,
					price_break INTEGER NOT NULL,
					break_amount REAL NOT NULL
				)')!

	app.db.exec('create table if not exists carts(
					id integer primary key,
					cart_id string
				)')!

	app.db.exec('create table if not exists customer_carts(
					id integer primary key,
					cart_id string,
					product_id integer,
					quantity integer
				)')!

	app.db.exec('INSERT OR IGNORE INTO banner (date, message) VALUES ("Aug 27", "Now roasting Brazil Cerado!")') or {
		panic(err)
	}
	app.db.exec('INSERT OR IGNORE INTO products (img, q_on_hand,  name, description, price, price_break, break_amount) VALUES
					("https://i.imgur.com/qhpLaUK.jpeg", "22", "Regular Blend", "Our most loved blend of coffee. Featuring coffees from South America and Northern Africa", "11.00", "4", "1")') or {
		panic(err)
	}
	app.db.exec('INSERT OR IGNORE INTO products (img, q_on_hand,  name, description, price, price_break, break_amount) VALUES
					("https://i.imgur.com/lRmCoAY.jpg", "4", "Reusable K Cup", "Save the earth, reuse this piece of plastic FOREVER", "4.99", "2", "1")') or {
		panic(err)
	}

	app.serve_static('/output.css', 'output.css')
	app.serve_static('/favicon.ico', 'favicon.ico')
	app.serve_static('/htmx.min.js', 'htmx.min.js')

	vweb.run(app, 8088)
}

[middleware: cart_middleware]
['/']
pub fn (app &App) index() vweb.Result {
	banner := app.get_banner()
	return $vweb.html()
}

[middleware: cart_middleware]
['/shop']
pub fn (mut app App) shop() vweb.Result {
	mut products := app.get_products() or { []Product{} }
	for i, product in products {
		products[i].q_on_hand = math.min(product.price_break, product.q_on_hand)
	}
	return $vweb.html()
}

[middleware: cart_middleware]
['/price_per']
pub fn (mut app App) price_per() vweb.Result {
	// should probably take in the items id, to send less over the network
	id := app.query['id']
	quantity := app.query['quantity${id}'].int()
	row := app.db.exec_param('SELECT price, price_break, break_amount FROM products WHERE id = ? LIMIT 1',
		id) or { panic(err) }
	if row.len == 0 {
		app.set_status(204, 'no product')
		return app.html('')
	}
	price := row[0].vals[0].f64()
	price_break := row[0].vals[1].int()
	break_amount := row[0].vals[2].int()
	mut result_price := price * quantity
	if quantity >= price_break {
		result_price -= break_amount * quantity
	}
	return app.text('
<span id="price${id}" hx-swap-oob="true">${result_price:.2f}</span>')
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
			img: row.vals[1]
			q_on_hand: row.vals[2].int()
			name: row.vals[3]
			description: row.vals[4]
			price: row.vals[5].f64()
			price_break: row.vals[6].int()
			break_amount: row.vals[7].int()
		}
		products << product
	}

	return products
}

[middleware: cart_middleware]
['/add_to_cart/:id']
pub fn (mut app App) add(id string) vweb.Result {
	if app.cart == Cart{} {
		return app.text('')
	}
	quantity := app.query['quantity${id}']
	app.db.exec_param_many('INSERT INTO customer_carts (cart_id, product_id, quantity)
						VALUES (?, ?, ?)',
		[app.get_cookie('cart_id') or { '' }, id, quantity]) or { panic(err) }
	last := app.db.last_insert_rowid()
	row := app.db.exec_param_many('SELECT img, name, price, price_break,
								break_amount, quantity, customer_carts.id as cart_index FROM products join
								customer_carts ON products.id = customer_carts.product_id
								WHERE customer_carts.cart_id = ? AND cart_index = ?',
		[app.get_cookie('cart_id') or { '' }, last.str()]) or { panic(err) }
	if row.len == 0 {
		return app.text('here') // query broken above
	}
	mut cart := []Cart_Product{}

	product := Cart_Product{
		product: Product{
			img: row[0].vals[0]
			name: row[0].vals[1]
			price: row[0].vals[2].f64()
			price_break: row[0].vals[3].int()
			break_amount: row[0].vals[4].int()
		}
		quantity: row[0].vals[5].int()
		cart_index: row[0].vals[6].int()
	}

	cart << product

	return $vweb.html()
}

[middleware: cart_middleware]
['/remove/:cart_index'; delete]
pub fn (mut app App) remove(cart_index string) vweb.Result {
	if cart_index == '' {
		return app.text('')
	}

	app.db.exec_param('DELETE FROM customer_carts WHERE id = ?', cart_index) or { panic(err) }
	rows := app.db.exec_param('SELECT img, name, price, price_break,
								break_amount, quantity, customer_carts.id as cart_index FROM products join
								customer_carts ON products.id = customer_carts.product_id
								WHERE customer_carts.cart_id = ?',
		app.cart.cart_id) or { panic(err) }
	if rows.len == 0 {
		return app.text('here') // query broken above
	}
	mut cart := []Cart_Product{}
	for row in rows {
		product := Cart_Product{
			product: Product{
				img: row.vals[0]
				name: row.vals[1]
				price: row.vals[2].f64()
				price_break: row.vals[3].int()
				break_amount: row.vals[4].int()
			}
			quantity: row.vals[5].int()
			cart_index: row.vals[6].int()
		}

		cart << product
	}

	return $vweb.html()
}

[middleware: cart_middleware]
['/clear_cart'; delete]
pub fn (mut app App) clear_cart() vweb.Result {
	cart_id := app.get_cookie('cart_id') or { return app.text('') }
	app.db.exec_param('DELETE FROM customer_carts WHERE cart_id = ?', cart_id) or {
		return app.text('customer_carts delete failed')
	}
	return app.text('
<div hx-swap-oob="true" id="cart_list">
<span class="text-stone-400 p-4 hidden last:block">Your shopping cart is empty</span>
</div>
')
}

pub fn actual_price(quantity int, price f64, price_break int, break_amount int) f64 {
	println(quantity)
	println(price)
	println(price_break)
	println(break_amount)
	mut actual := price * quantity
	if quantity >= price_break {
		actual -= break_amount * quantity
	}
	println(actual)
	return actual
}

pub fn (mut app App) cart_middleware() bool {
	cart_id := app.get_cookie('cart_id') or { '' }
	res := app.db.exec_param('SELECT id from carts where cart_id = ?', cart_id) or { panic(err) }
	if cart_id.len == 0 || res.len == 0 {
		println('assigning a new cart_id')
		uuid := rand.uuid_v4()
		app.db.exec_param('INSERT INTO carts (cart_id) VALUES (?)', uuid) or { panic(err) }
		app.set_cookie(name: 'cart_id', value: uuid)
		app.cart.cart_id = uuid
		return true
	}
	// id := res[0].vals[0]
	rows := app.db.exec_param('SELECT img, name, price, price_break,
								break_amount, quantity, customer_carts.id as cart_index FROM products join
								customer_carts ON products.id = customer_carts.product_id
								WHERE customer_carts.cart_id = ?',
		cart_id) or { panic(err) }
	if rows.len == 0 {
		app.cart.cart_id = cart_id
		return true
	}
	mut cart := []Cart_Product{}
	for row in rows {
		product := Cart_Product{
			product: Product{
				img: row.vals[0]
				name: row.vals[1]
				price: row.vals[2].f64()
				price_break: row.vals[3].int()
				break_amount: row.vals[4].int()
			}
			quantity: row.vals[5].int()
			cart_index: row.vals[6].int()
		}

		cart << product
	}
	app.cart = Cart{
		cart_id: cart_id
		items: cart
	}
	return true
}
