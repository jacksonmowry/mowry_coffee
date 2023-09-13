module main

import json
import net.http
import os

enum Billing_Type as u8 {
	one_time
	recurring
}

struct Stripe_Product_Response {
mut:
	data []struct {
	mut:
		id            string
		default_price string
		description   string
		images        []string
		name          string
		metadata      map[string]string
		prices        []struct {
			price_id      string
			billing       Billing_Type
			default_price bool
			unit_amount   int
		}
	}
}

struct Stripe_Price_Response {
	data []struct {
		id           string
		product      string
		billing_type string [json: 'type']
		unit_amount  int
	}
}

struct Stripe_Session_Response {
	url string
}

struct Stripe_Create_Session {
	mode string
mut:
	line_items []struct {
	mut:
		price    string
		quantity int
	}

	success_url                 string
	cancel_url                  string
	shipping_address_collection struct {
		allowed_countries []string
	}

	shipping_options []struct {
		shipping_rate string
	}
}

fn (mut app App) populate_products(stripe_key string) ?[]Product {
	product_url := 'https://api.stripe.com/v1/products?limit=100'
	head := http.new_custom_header_from_map({
		'Authorization': 'Bearer ${stripe_key}'
	}) or {
		println('new custom failed')
		return none
	}
	product_response := http.fetch(url: product_url, method: .get, header: head) or { return none }.body
	mut stripe_products := json.decode(Stripe_Product_Response, product_response) or { return none }
	prices_url := 'https://api.stripe.com/v1/prices?limit=100'
	prices_response := http.fetch(url: prices_url, method: .get, header: head) or { return none }.body
	prices := json.decode(Stripe_Price_Response, prices_response) or { return none }

	for mut product in stripe_products.data {
		for price in prices.data {
			billing := Billing_Type.from_string(price.billing_type) or { return none }
			if price.id == product.default_price {
				product.prices.prepend(struct {price.id, billing, true, price.unit_amount})
			} else if price.product == product.id {
				product.prices << struct {price.id, billing, false, price.unit_amount}
			}
		}
	}

	os.mkdir('./assets', os.MkdirParams{}) or {
		if err.str() != 'File exists' {
			println('error during mkdir: ${err}')
			return error('cannot make assets dir')
		}
	}

	mut threads := []thread string{}
	for i, mut product in stripe_products.data {
		// product.images[0] = convert_img_to_webp(&product.images[0], i) or { return none }
		threads << spawn convert_img_to_webp(&product.images[0], i)
	}
	new_webp := threads.wait()

	mut products := []Product{}
	for i, product in stripe_products.data {
		mut tmp := Product{
			id: i + 1
			// img: product.images[0]
			img: new_webp[i]
			name: product.name
			description: product.description
			default_price: product.prices[0].unit_amount
			default_price_id: product.prices[0].price_id
			billing: product.prices[0].billing
			stripe_product_id: product.id
			weight: product.metadata['weight'].int()
		}
		if bulk_discount := product.metadata['bulk_discount'] {
			tmp.price_break_at = bulk_discount.int()
			tmp.bulk_price = product.prices[1].unit_amount
			tmp.bulk_price_id = product.prices[1].price_id
		}

		app.db.exec('INSERT INTO products (img, name, description, default_price,
									default_price_id, bulk_price, bulk_price_id,
									price_break_at, billing, stripe_product_id, weight)
									VALUES ("${tmp.img}", "${tmp.name}", "${tmp.description}",
											"${tmp.default_price}", "${tmp.default_price_id}",
											"${tmp.bulk_price}", "${tmp.bulk_price_id}",
											"${tmp.price_break_at}", "${tmp.billing}",
											"${tmp.stripe_product_id}", "${tmp.weight}")') or {
			return none
		}
		products << tmp
	}

	return products
}

fn (mut app App) start_checkout(stripe_key string, shipping bool, one_time_shipping int, recurring_shipping int) ?string {
	url := 'https://api.stripe.com/v1/checkout/sessions'
	mut header := http.Header{}
	header.add_custom('Authorization', 'Bearer ${stripe_key}') or { return none }
	header.add_custom('Content-Type', 'application/x-www-form-urlencoded') or { return none }
	mut mode := 'payment'
	mut items := map[string]string{}
	if app.cart.items.len == 0 {
		return none
	}
	mut shipping_idx := 0
	for i, item in app.cart.items {
		if item.product.billing == .recurring {
			mode = 'subscription'
		}
		items['line_items[${i}][price]'] = item.product.default_price_id
		items['line_items[${i}][quantity]'] = item.quantity.str()
		shipping_idx++
	}
	items['success_url'] = 'http://mowry.coffee/'
	items['cancel_url'] = 'http://mowry.coffee/checkout'
	items['mode'] = mode
	items['shipping_address_collection[allowed_countries][0]'] = 'US'
	if shipping && one_time_shipping > 0 && recurring_shipping > 0 {
		items['line_items[${shipping_idx}][price_data][currency]'] = 'USD'
		items['line_items[${shipping_idx}][quantity]'] = '1'
		items['line_items[${shipping_idx}][price_data][product_data][name]'] = 'Shipping'
		items['line_items[${shipping_idx}][price_data][product_data][description]'] = 'Recurring Shipping through UPS or USPS'
		items['line_items[${shipping_idx}][price_data][unit_amount]'] = recurring_shipping.str()
		items['line_items[${shipping_idx}][price_data][recurring][interval]'] = 'month'
		items['line_items[${shipping_idx + 1}][price_data][currency]'] = 'USD'
		items['line_items[${shipping_idx + 1}][quantity]'] = '1'
		items['line_items[${shipping_idx + 1}][price_data][product_data][name]'] = 'Shipping'
		items['line_items[${shipping_idx + 1}][price_data][product_data][description]'] = 'One Time Shipping through UPS or USPS'
		items['line_items[${shipping_idx + 1}][price_data][unit_amount]'] = one_time_shipping.str()
	} else if shipping && recurring_shipping > 0 {
		items['line_items[${shipping_idx}][price_data][currency]'] = 'USD'
		items['line_items[${shipping_idx}][quantity]'] = '1'
		items['line_items[${shipping_idx}][price_data][product_data][name]'] = 'Shipping'
		items['line_items[${shipping_idx}][price_data][product_data][description]'] = 'Recurring Shipping through UPS or USPS'
		items['line_items[${shipping_idx}][price_data][unit_amount]'] = recurring_shipping.str()
		items['line_items[${shipping_idx}][price_data][recurring][interval]'] = 'month'
	} else if shipping && one_time_shipping > 0 {
		items['line_items[${shipping_idx}][price_data][currency]'] = 'USD'
		items['line_items[${shipping_idx}][quantity]'] = '1'
		items['line_items[${shipping_idx}][price_data][product_data][name]'] = 'Shipping'
		items['line_items[${shipping_idx}][price_data][product_data][description]'] = 'One Time Shipping through UPS or USPS'
		items['line_items[${shipping_idx}][price_data][unit_amount]'] = one_time_shipping.str()
	} else if !shipping {
		items['line_items[${shipping_idx}][price_data][currency]'] = 'USD'
		items['line_items[${shipping_idx}][quantity]'] = '1'
		items['line_items[${shipping_idx}][price_data][product_data][name]'] = 'Local Delivery'
		items['line_items[${shipping_idx}][price_data][product_data][description]'] = 'Free delivery in the Kingston Area'
		items['line_items[${shipping_idx}][price_data][unit_amount]'] = '0'
	}
	mut body := http.url_encode_form_data(items)

	fc := http.FetchConfig{
		url: url
		method: .post
		header: header
		data: body
	}

	response := http.fetch(fc) or { return none }.body
	return json.decode(Stripe_Session_Response, response) or { return none }.url
}

fn convert_img_to_webp(url string, pos int) string {
	http.download_file(url, '/home/jarch/mowry_coffee/assets/${pos}.png') or { println(err) }

	os.execute('convert ./assets/${pos}.png ./assets/${pos}.webp')
	os.rm('./assets/${pos}.png') or { println(err) }

	return '${pos}.webp'
}
