/* Publications: filter by type + live search. Plain JS, no dependencies. */
(function () {
	var pills = document.querySelectorAll('.pub-filters .pill');
	var search = document.getElementById('pub-search');
	var items = document.querySelectorAll('.pub');
	var years = document.querySelectorAll('.pub-year');
	var empty = document.querySelector('.pub-empty');
	var filter = 'all';

	function apply() {
		var q = (search.value || '').toLowerCase().trim();
		var shown = 0;
		items.forEach(function (li) {
			var okType = filter === 'all' || li.getAttribute('data-type') === filter;
			var okText = !q || li.textContent.toLowerCase().indexOf(q) !== -1;
			var ok = okType && okText;
			li.hidden = !ok;
			if (ok) shown++;
		});
		years.forEach(function (y) {
			y.hidden = !y.querySelector('.pub:not([hidden])');
		});
		empty.hidden = shown !== 0;
	}

	pills.forEach(function (b) {
		b.addEventListener('click', function () {
			pills.forEach(function (x) { x.classList.remove('is-active'); });
			b.classList.add('is-active');
			filter = b.getAttribute('data-filter');
			apply();
		});
	});
	search.addEventListener('input', apply);
})();
