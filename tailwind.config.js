/** @type {import('tailwindcss').Config} */
module.exports = {
  content: ["./*.{html,v}"],
  theme: {
    extend: {
      // ...
    },
  },
  plugins: [
    require('@tailwindcss/typography')
  ],
}
