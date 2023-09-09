module main

import vweb
import db.sqlite
import math
import rand
import crypto.bcrypt

struct App {
	vweb.Context
mut:
	db   sqlite.DB
	cart Cart
}

struct Product {
	id int
mut:
	img               string
	q_on_hand         int
	name              string
	description       string
	default_price     int
	default_price_id  string
	bulk_price        int
	bulk_price_id     string
	price_break_at    int
	billing           Billing_Type
	stripe_product_id string
	weight            int
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
		db: sqlite.connect('coffee.db')!
	}

	app.db.exec('CREATE TABLE IF NOT EXISTS banner(
					id INTEGER PRIMARY KEY,
					date TEXT NOT NULL,
					message TEST NOT NULL
 				)')!

	app.db.exec('CREATE TABLE IF NOT EXISTS products(
					id INTEGER PRIMARY KEY,
					img TEXT NOT NULL,
					q_on_hand INTEGER DEFAULT 0,
					name TEXT NOT NULL UNIQUE,
					description TEXT NOT NULL,
					default_price INTEGER NOT NULL,
					default_price_id TEXT NOT NULL,
					bulk_price INTEGER,
					bulk_price_id TEXT,
					price_break_at INTEGER,
					billing TEXT NOT NULL,
					stripe_product_id TEXT NOT NULL,
					weight INTEGER
				)')!

	app.db.exec('create table if not exists carts(
					id integer primary key,
					cart_id string
				)')!

	app.db.exec('create table if not exists customer_carts(
					id integer primary key,
					cart_id string,
					product_id integer,
					quantity integer,
					subscription BOOLEAN DEFAULT "FALSE"
				)')!

	app.db.exec('create table if not exists metrics(
					id integer primary key,
					sales integer
				)')!

	app.db.exec('create table if not exists secrets(
					id integer primary key,
					name text,
					secret text
				)')!

	app.db.exec('create table if not exists admin(
					id integer primary key,
					password text,
					cookie text
				)')!

	app.db.exec('INSERT INTO metrics (sales) VALUES ("0")')!

	app.serve_static('/output.css', 'output.css')
	app.serve_static('/favicon.ico', 'favicon.ico')
	app.serve_static('/htmx.min.js', 'htmx.min.js')

	vweb.run(app, 8080)
}

[middleware: cart_middleware]
pub fn (mut app App) not_found() vweb.Result {
	app.set_status(404, 'Not Found')
	return app.html('<h1>404: Oops, You Spilled the beans!</h1>
<a href="/">Take me home</a>')
}

[middleware: cart_middleware]
['/']
pub fn (app &App) index() vweb.Result {
	banner := app.get_banner()
	return $vweb.html()
}

[middleware: cart_middleware]
['/about']
pub fn (app &App) aboutus() vweb.Result {
	return $vweb.html()
}

['/admin']
pub fn (mut app App) adminlogin() vweb.Result {
	return $vweb.html()
}

['/login'; post]
pub fn (mut app App) login() vweb.Result {
	password := app.form['password'] or { return app.redirect('/') }
	row := app.db.exec('SELECT password FROM admin') or {
		println('cannot fetch admin password from db')
		return app.redirect('/')
	}
	if row.len == 0 {
		hashed_pass := bcrypt.generate_from_password(password.bytes(), 10) or {
			println('error hashing password')
			return app.redirect('/')
		}
		app.db.exec_param('INSERT INTO admin (password) values (?)', hashed_pass) or {
			println('error inserting new password')
			return app.redirect('/')
		}
	} else {
		bcrypt.compare_hash_and_password(password.bytes(), row[0].vals[0].bytes()) or {
			println('bad password for admin login')
			return app.redirect('/')
		}
	}
	uuid := rand.uuid_v4()
	app.db.exec('UPDATE admin SET cookie = "${uuid}"') or {
		println('error updating cookie')
		return app.redirect('/')
	}
	app.set_cookie(name: 'admin_password', value: uuid)
	return app.redirect('/dashboard')
}

[middleware: admin_middleware]
['/dashboard']
pub fn (mut app App) admin() vweb.Result {
	products := app.get_all_products() or { []Product{} }
	cart_count := app.count_carts() or { 0 }

	return $vweb.html()
}

[middleware: admin_middleware]
['/banner'; post]
pub fn (mut app App) banner() vweb.Result {
	date := app.form['date'] or {
		println('failed to get form date')
		return app.redirect('/')
	}
	msg := app.form['banner'] or {
		println('failed to get form banner')
		return app.redirect('/')
	}
	app.db.exec_param_many('UPDATE banner set date = ?, message = ?', [date, msg]) or {
		println('failed to update banner')
		return app.text('
                        <button type="submit" class="flex items-center justify-center gap-2 bg-red-500 rounded py-1 px-2 text-white text-center">
                            Failed</button>
')
	}
	return app.text('
<a href="/" class="flex items-center justify-center gap-2 bg-green-500 rounded py-1 px-2 text-white text-center">
Success | Check it out?</a>
')
}

['/stripe_key'; post]
pub fn (mut app App) stripekey() vweb.Result {
	stripe_key := app.form['stripe_key'] or { return app.text('Please provide a valid key') }
	if stripe_key.len != 107 {
		return app.text('Please provide the full 107 character secret key')
	}
	app.db.exec_param('insert into secrets (name, secret) values ("stripe key", ?)', stripe_key) or {
		return app.text('Error updating stripe key, please try again later')
	}
	products := app.populate_products(stripe_key) or {
		return app.text('Error fetching product information, please try again later')
	}

	return $vweb.html()
}

[middleware: cart_middleware]
['/shop']
pub fn (mut app App) shop() vweb.Result {
	mut products := app.get_subscriptions() or { []Product{} }
	mut k_cup := Product{}
	if products.len > 0 {
		k_cup = products.last()
		k_cup.q_on_hand = math.min(k_cup.q_on_hand, 2)
		products.pop()
	}
	return $vweb.html()
}

[middleware: cart_middleware]
['/checkout']
pub fn (mut app App) checkout() vweb.Result {
	return $vweb.html()
}

['/zip'; post]
pub fn (mut app App) zip() vweb.Result {
	zip_code := app.form['zip'] or { return app.text('') }
	if zip_code == '37763' || zip_code == '37748' {
		return app.text('<option value="local" selected>Local Delivery</option>
						<option value="shipping">Shipping</option>
<div hx-swap-oob="true" id="symbol">
<svg class="w-6 h-8 stroke-green-800 self-end inline" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="1.5" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg">
  <path d="M4.5 12.75l6 6 9-13.5" stroke-linecap="round" stroke-linejoin="round"></path>
</svg>
</div>')
	} else {
		return app.text('<option value="shipping" selected>Shipping</option>
<div hx-swap-oob="true" id="symbol">
<svg class="w-6 h-8 stroke-red-800 self-end inline" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="1.5" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg">
  <path d="M6 18L18 6M6 6l12 12" stroke-linecap="round" stroke-linejoin="round"></path></svg>
</div>
')
	}
}

[middleware: cart_middleware]
['/begin_checkout'; post]
pub fn (mut app App) begincheckout() vweb.Result {
	delivery_method := app.form['delivery_method'] or { return app.redirect('/') }
	shipped := delivery_method == 'shipping'
	one_time_shipping, recurring_shipping := app.calculate_shipping(shipped) or {
		return app.redirect('/shop')
	}
	rows := app.db.exec('select secret from secrets') or { return app.redirect('/shop') }
	if rows.len == 0 {
		return app.redirect('/shop')
	}
	stripe_key := rows[0].vals[0]
	stripe_url := app.start_checkout(stripe_key, shipped, one_time_shipping, recurring_shipping) or {
		return app.redirect('/shop')
	}
	return app.redirect(stripe_url)
}

[middleware: cart_middleware]
['/tab/:type']
pub fn (mut app App) tab(category string) vweb.Result {
	mut products := []Product{}
	if category == 'single' {
		products = app.get_products() or { []Product{} }
		for i, product in products {
			products[i].q_on_hand = math.min(product.price_break_at, product.q_on_hand)
		}
	} else {
		products = app.get_subscriptions() or { []Product{} }
	}
	return $vweb.html()
}

[middleware: cart_middleware]
['/price_per']
pub fn (mut app App) price_per() vweb.Result {
	// should probably take in the items id, to send less over the network
	id := app.query['id']
	quantity := app.query['quantity${id}'].int()
	row := app.db.exec_param('SELECT default_price, bulk_price, price_break_at FROM products WHERE id = ? LIMIT 1',
		id) or {
		println('unable to get price in price_per')
		app.set_status(204, 'no product')
		return app.html('')
	}
	if row.len == 0 {
		app.set_status(204, 'no product')
		return app.html('')
	}
	mut result_price := row[0].vals[0].int()
	if quantity >= row[0].vals[2].int() {
		result_price = row[0].vals[1].int()
	}
	return app.text('
<span id="price${id}" hx-swap-oob="true">${result_price * quantity / f64(100):.2f}</span>')
}

fn (app &App) get_banner() string {
	row := app.db.exec_one('SELECT * FROM banner ORDER BY id DESC LIMIT 1') or {
		return 'Now Roasting Brazil Cerado!'
	}
	return '${row.vals[1]}: ${row.vals[2]}'
}

fn (app &App) get_products() ?[]Product {
	rows := app.db.exec('SELECT * FROM products where billing == "one_time"') or {
		println('unable to fetch subscription products')
		return none
	}
	if rows.len == 0 {
		println('unable to fetch subscription products')
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
			default_price: row.vals[5].int()
			price_break_at: row.vals[9].int()
		}
		products << product
	}

	return products
}

fn (app &App) get_subscriptions() ?[]Product {
	rows := app.db.exec('SELECT * FROM products where billing == "recurring" OR name = "Reusable K-Cup" ORDER BY default_price ASC') or {
		println('unable to fetch subscription products')
		return none
	}
	if rows.len == 0 {
		println('unable to fetch subscription products')
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
			default_price: row.vals[5].int()
		}
		products << product
	}

	return products.reverse()
}

fn (app &App) get_all_products() ?[]Product {
	rows := app.db.exec('SELECT * FROM products') or {
		println('unable to fetch all products')
		return none
	}
	if rows.len == 0 {
		return none
	}

	mut products := []Product{}
	for row in rows {
		mut product := Product{row.vals[0].int(), row.vals[1], row.vals[2].int(), row.vals[3], row.vals[4], row.vals[5].int(), row.vals[6], row.vals[7].int(), row.vals[8], row.vals[9].int(), Billing_Type.one_time, row.vals[11], row.vals[12].int()}
		if row.vals[10] == Billing_Type.recurring.str() {
			product.billing = .recurring
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
	if quantity.len > 0 {
		app.db.exec_param_many('INSERT INTO customer_carts (cart_id, product_id, quantity)
						VALUES (?, ?, ?)',
			[app.get_cookie('cart_id') or { '' }, id, quantity]) or {
			println('failed to insert one_time item')
			return app.redirect('/shop')
		}
	} else {
		app.db.exec_param_many('INSERT INTO customer_carts (cart_id, product_id, subscription)
						VALUES (?, ?, ?)',
			[app.get_cookie('cart_id') or { '' }, id, 'TRUE']) or {
			println('failed to insert subscription item')
			return app.redirect('/shop')
		}
	}
	last_res := app.db.exec('SELECT last_insert_rowid()') or {
		println('failed selecting last_insert_rowid()')
		return app.redirect('/shop')
	}
	last := last_res[0].vals[0]
	row := app.db.exec_param_many('SELECT img, name, default_price, price_break_at,
								bulk_price, quantity, customer_carts.id as cart_index, customer_carts.subscription,
								default_price_id, bulk_price_id FROM products join
								customer_carts ON products.id = customer_carts.product_id
								WHERE customer_carts.cart_id = ? AND cart_index = ?',
		[app.get_cookie('cart_id') or { '' }, last]) or {
		println('failed to fetch product after insert into cart')
		return app.redirect('/shop')
	}
	if row.len == 0 {
		println('no product after insert into cart')
		return app.redirect('/shop')
	}
	mut cart := []Cart_Product{}
	product := Cart_Product{
		product: Product{
			img: row[0].vals[0]
			name: row[0].vals[1]
			default_price: if quantity.int() >= row[0].vals[3].int() && row[0].vals[7] == 'FALSE' {
				row[0].vals[4].int()
			} else {
				row[0].vals[2].int()
			}
			default_price_id: if quantity.int() >= row[0].vals[3].int() && row[0].vals[7] == 'FALSE' {
				row[0].vals[9]
			} else {
				row[0].vals[8]
			}
			billing: if row[0].vals[7] == 'TRUE' {
				Billing_Type.recurring
			} else {
				Billing_Type.one_time
			}
		}
		quantity: if quantity.int() != 0 { row[0].vals[5].int() } else { 1 }
		cart_index: row[0].vals[6].int()
	}
	cart << product

	return $vweb.html()
}

[middleware: cart_middleware]
['/remove/:cart_index'; delete]
pub fn (mut app App) remove(cart_index string) vweb.Result {
	if cart_index == '' || app.cart == Cart{} {
		return app.html('<div>No user found</div>')
	}

	app.db.exec_param('DELETE FROM customer_carts WHERE id = ?', cart_index) or {
		return app.html('<div>Error removing from cart</div>')
	}
	rows := app.db.exec_param('SELECT img, name, default_price, price_break_at,
								bulk_price, quantity, customer_carts.id as cart_index, customer_carts.subscription FROM products join
								customer_carts ON products.id = customer_carts.product_id
								WHERE customer_carts.cart_id = ?',
		app.cart.cart_id) or {
		println('failed to fetch cart after delete')
		return app.redirect('/shop')
	}
	if rows.len == 0 {
		cart := []Cart_Product{}
		return $vweb.html()
	}
	mut cart := []Cart_Product{}
	for row in rows {
		product := Cart_Product{
			product: Product{
				img: row.vals[0]
				name: row.vals[1]
				default_price: if row.vals[5].int() >= row.vals[3].int() && row.vals[7] == 'FALSE' {
					row.vals[4].int()
				} else {
					row.vals[2].int()
				}
				billing: if row.vals[7] == 'TRUE' {
					Billing_Type.recurring
				} else {
					Billing_Type.one_time
				}
			}
			quantity: if row.vals[7] == 'FALSE' {
				row.vals[5].int()
			} else {
				1
			}
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
<span class="text-center text-stone-400 p-4 hidden last:block">Your shopping cart is empty</span>
</div>
')
}

['/update_q/:id'; post]
pub fn (mut app App) updateq(id int) vweb.Result {
	new_q := app.form['new_q${id}'] or { '0' }
	if new_q == '0' {
		return app.text('')
	}
	app.db.exec_param_many('UPDATE products SET q_on_hand = ? WHERE id = ?', [new_q, id.str()]) or {
		return app.text('bork')
	}

	return app.text('<input class="w-5/6 inline" type="number" id="new_q@product.id" name="new_q@product.id"
                           hx-post="/update_q/@product.id"
                           hx-swap="morph"
                           hx-trigger="keyup changed delay:1000ms, new_q@product.id"
                           hx-indicator=".htmx-indicator"
                           value="${new_q}">')
}

['/webhook'; post]
pub fn (mut app App) webhook() vweb.Result {
	app.db.exec_none('UPDATE metrics set sales = sales + 1')
	return app.ok('')
}

fn (app &App) sales() int {
	row := app.db.exec('SELECT sales FROM metrics LIMIT 1') or { return 0 }
	if row.len == 0 {
		return 0
	}
	return row[0].vals[0].int()
}

fn (app &App) count_carts() ?int {
	count := app.db.exec('SELECT COUNT(*) FROM carts') or { return none }
	if count.len == 0 {
		return none
	}
	return count[0].vals[0].int()
}

fn (app &App) get_weight() ?(int, int) {
	if app.cart.items.len == 0 {
		return none
	}
	mut one_time_weight := 0
	mut recurring_weight := 0
	for item in app.cart.items {
		if item.product.billing == .recurring {
			recurring_weight += item.product.weight * item.quantity
		} else {
			one_time_weight += item.product.weight * item.quantity
		}
	}

	return one_time_weight, recurring_weight
}

fn shipping_table(weight int) int {
	return match weight {
		0 {
			0
		}
		1...2 {
			300
		}
		3...14 {
			600
		}
		15...26 {
			900
		}
		27...38 {
			1000
		}
		39...50 {
			1100
		}
		else {
			1350
		}
	}
}

fn (app &App) calculate_shipping(shipping bool) ?(int, int) {
	if !shipping {
		return 0, 0
	}
	one_time_weight, recurring_weight := app.get_weight() or { return none }
	total_shipping := shipping_table(one_time_weight + recurring_weight)
	recurring_shipping := shipping_table(recurring_weight)
	one_time_shipping := total_shipping - recurring_shipping
	return one_time_shipping, recurring_shipping
}

pub fn (mut app App) cart_middleware() bool {
	cart_id := app.get_cookie('cart_id') or { '' }
	res := app.db.exec_param('SELECT id from carts where cart_id = ?', cart_id) or {
		println('failed getting cart based on cart_id in middleware')
		return true
	}
	if cart_id.len == 0 || res.len == 0 {
		println('assigning a new cart_id')
		uuid := rand.uuid_v4()
		app.db.exec_param('INSERT INTO carts (cart_id) VALUES (?)', uuid) or {
			println('failed assigning cart_id')
			return true
		}
		app.set_cookie(name: 'cart_id', value: uuid)
		app.cart.cart_id = uuid
		return true
	}
	// id := res[0].vals[0]
	rows := app.db.exec_param('SELECT img, name, default_price, price_break_at,
								bulk_price, quantity, customer_carts.id as cart_index, customer_carts.subscription,
								default_price_id, bulk_price_id, weight FROM products join
								customer_carts ON products.id = customer_carts.product_id
								WHERE customer_carts.cart_id = ?',
		cart_id) or {
		println('failed getting all cart')
		return true
	}
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
				default_price: if row.vals[5].int() >= row.vals[3].int() && row.vals[7] == 'FALSE' {
					row.vals[4].int()
				} else {
					row.vals[2].int()
				}
				default_price_id: if row.vals[5].int() >= row.vals[3].int()
					&& row.vals[7] == 'FALSE' {
					row.vals[9]
				} else {
					row.vals[8]
				}
				billing: if row.vals[7] == 'TRUE' {
					Billing_Type.recurring
				} else {
					Billing_Type.one_time
				}
				weight: row.vals[10].int()
			}
			quantity: if row.vals[7] == 'FALSE' {
				row.vals[5].int()
			} else {
				1
			}
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

pub fn (mut app App) admin_middleware() bool {
	cookie := app.get_cookie('admin_password') or {
		app.redirect('/')
		return false
	}
	row := app.db.exec_one('SELECT * FROM admin') or {
		println('failed to get admin row')
		app.redirect('/')
		return false
	}
	return cookie == row.vals[2]
}
