const path = require('path');
const HtmlWebpackPlugin = require('html-webpack-plugin');
const MiniCssExtractPlugin = require('mini-css-extract-plugin');
const TerserPlugin = require('terser-webpack-plugin');

// Plain static files: index.html, app.js, app.css and the icons beside them.
// The server hands out index.html for `/` and the rest under /_irisin/ by
// bare filename, and its CSP allows script and style from that origin only:
// nothing inline. Fila's WebUI is built the same way.
module.exports = {
  entry: './src/index.tsx',
  output: { path: path.resolve(__dirname, 'dist'), filename: 'app.js', publicPath: '/_irisin/', clean: true },
  resolve: { extensions: ['.tsx', '.ts', '.js'] },
  module: {
    rules: [
      { test: /\.tsx?$/, use: 'ts-loader', exclude: /node_modules/ },
      { test: /\.css$/, use: [MiniCssExtractPlugin.loader, 'css-loader'] },
      // Flat names: the server serves /_irisin/<name> and refuses subdirectories.
      { test: /\.png$/, type: 'asset/resource', generator: { filename: '[name][ext]' } },
    ],
  },
  plugins: [
    new MiniCssExtractPlugin({ filename: 'app.css' }),
    new HtmlWebpackPlugin({ template: './src/template.html', minify: false }),
  ],
  optimization: { minimizer: [new TerserPlugin({ extractComments: false })] },
  performance: { hints: false },
  devtool: false,
};
