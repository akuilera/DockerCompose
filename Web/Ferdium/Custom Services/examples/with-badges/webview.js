// Poll the page every ~1s and report direct/indirect unread counts plus the
// active dialog title. The selectors below are placeholders — open the
// service's developer tools (Cmd/Ctrl+Alt+Shift+I) to find the real ones.
module.exports = Ferdium => {
  const getMessages = () => {
    let direct = 0;
    let indirect = 0;
    const elements = document.querySelectorAll('.list-item');
    for (const element of elements) {
      const badge = element.querySelector('.badge');
      if (badge) {
        const value = Ferdium.safeParseInt(badge.textContent);
        direct += value;
      }
    }

    Ferdium.setBadge(direct, indirect);
  };

  const getActiveDialogTitle = () => {
    Ferdium.setDialogTitle(document.title);
  };

  Ferdium.loop(getMessages);
  Ferdium.loop(getActiveDialogTitle);
};