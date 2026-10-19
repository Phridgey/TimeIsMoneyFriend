# Time is Money, Friend

An auction house addon for World of Warcraft 1.12 (Turtle WoW / OctoWow), based on
[aux](https://github.com/shirsig/aux-addon-vanilla) by shirsig and its Turtle WoW
version. All credit for aux itself goes to its authors (their documentation is in
`README_aux.md`); this is a personal fork with extra features.

Command: **`/timf`** (all of aux's usual options).

## Install

Install it like any addon from GitHub: the folder must be called `TimeIsMoneyFriend`
inside `Interface\AddOns` (an addon installer that takes the GitHub link does this for
you). With **Code → Download ZIP**, GitHub names the folder `TimeIsMoneyFriend-main`:
rename it to `TimeIsMoneyFriend`.

**Do not run it together with aux** – both use the same internal names and saved data,
so disable aux first. To keep your aux price history and settings, copy
`WTF\Account\<account>\SavedVariables\aux-addon.lua` to `TimeIsMoneyFriend.lua` in the
same folder (with the game closed).

## What is different from aux

**Ledger tab** – daily bars of gold spent buying, deposits lost on unsold auctions, gold
from sales, items bought, auctions sold and expired, with a toggle for each, 7/14/30/90
day ranges and a net total.

**Trades tab** – every item you traded, and groups such as *Level 51-59 green armour*;
tick them to graph the lowest auction house price per day with your own purchase and
sale prices and the quantities bought and sold.

**Professions panel** – beside the Search tab: open each profession window once and
click a recipe to search its item and all its materials at once. These searches never
auto-buy.

**Post tab** – item type, rarity and sort-order filters, and a compact list that fits
twice as many items.

**Shift + click a bag item** while the window is open: on the Search tab it searches for
it, on the Post tab it picks it for posting.

**Tooltips** – a small graph of your recent searches; the per-unit value of enchanting
and crafting materials when crafted into common products (oils, elixirs, enchanted
bars and leather, Greater Fire Protection Potion) against selling them as they are;
two-day prices for crafting costs.

**Oils** – wizard and mana oils are priced and posted per oil (they stack on this
server), and partly used oils are never posted.

## Notes

- Trading stats start from when you install it. Sales, won bids and expired auctions
  are counted when you take them from the mail; buyouts and deposits immediately.
- The professions panel and the Post tab filters come from another fork of aux and were
  merged into this one.
