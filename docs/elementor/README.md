# Elementor copy

`phonefold.html` goes into an Elementor **HTML** widget on marcdeller.com, and
`elementor-widget-markdown.css` into that widget's **Advanced → Custom CSS** box (it uses
Elementor's `selector` token, so it resolves only there, not in a browser or a global
stylesheet). `phonefold.preview.html` is a local styled check and is not published.

The screenshot is referenced by its **raw GitHub URL** here rather than by the relative
`docs/screenshots/` path the repository README uses. A relative path is meaningless once the
markup is pasted into a page on another host, and it would render as a broken image.

Regenerate after any README change:

```bash
cp ../../README.md phonefold.md
python3 ~/.claude/skills/marcs-vibe-coding/scripts/readme_forge.py phonefold.md
```
