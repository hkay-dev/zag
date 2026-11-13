---
type: guide
summary: Read Zag's size on its website, compare it with other editors, and download the Mac app.
covers:
  - site/
---

# Zag's website

Choose **Download for Mac** to download Zag. The number beside the button is the size of the compressed disk image. One KiB is 1,024 bytes.

## The square

The orange square at the top of the page is Zag's whole program, drawn with one pixel for each byte. Move the pointer over it to read the bytes under the cursor, the way a hex editor shows them. On a narrow screen the page draws the square at half size and says so.

## Other editors at the same scale

Scroll through **Size** to watch the page zoom out. The first frame shows Zag's own square at full size: its executable's bytes, with hatching for the other files in the app. Each outlined square after it is another editor's app as it sits on disk, drawn at the same one pixel per byte. The page tiles the square that it is fitting with cells the size of Zag, so you can count how many copies of Zag fit. Each editor's name, size and multiple sit on a dashed line at the right, level with its square's bottom edge; on a phone the strip at the bottom shows the current editor. The table under it lists each editor's version, download size and size on disk, with the date that we measured them.

## Speed, and what Zag leaves out

**Speed** shows times that Zag's own performance tests recorded on an M5 Max MacBook Pro. The bar beside each time draws it against one frame of a 120 Hz display: the launch time as a row of frames, and a keystroke or a scroll as the filled share of a single frame. **Not included** lists what an IDE ships and Zag doesn't, such as plugins, autocomplete and linting.

## Screenshots

Under **Included**, choose a theme beside the app screenshot to preview its colors. This changes the screenshot, not your installed app. Hover a highlighted feature name to see a real screenshot of it; on a touch screen the same screenshots sit below the paragraph.

In the writing preview, choose **Source** or **Preview**, or drag the divider to compare the Markdown and its rendered page. Open either focus screenshot to see the full window. Press Escape to close it.

## Appearance and motion

Choose **System**, **Light** or **Dark** in the header to change the website's appearance. Use the pause control beside it to stop the page's animation; the page then shows every section as a still picture. The page also stays still when your Mac has Reduce Motion turned on.

## Checking the download

The **Download** section lists the disk image's file name, exact size and SHA-256 checksum. Run `shasum -a 256` on the file that you downloaded and compare the result. The drawing under the button shows how many copies of the download fit on one floppy disk, to scale.

Follow **User guide** for editing commands, shortcuts and settings. Follow **Source** to read Zag's code.
