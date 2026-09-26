// Rename the class to your service (e.g. "MyMessenger") when copying.
module.exports = Ferdium =>
  class CustomService extends Ferdium {
    overrideUserAgent() {
      return 'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';
    }
  };