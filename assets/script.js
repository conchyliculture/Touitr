// Data
let allPosts = [];

// Configuration
const POSTS_PER_PAGE = 5;
let currentIndex = 0;
let isLoading = false;
let searchQuery = "";
let filteredPosts = [];

// Advanced search filters
let mediaOnly = false;
let fromDate = null;
let untilDate = null;

// Incremented every time the filters change, so that a page load still
// waiting on its timeout doesn't append posts to a timeline that moved on
let loadToken = 0;
let base_url = "PLACEHOLDER_BASE_URL";
let twitter_host = "PLACEHOLDER_TWITTER_HOST";

const POST_TEMPLATE = `PLACEHOLDER_POST_TEMPLATE`

// DOM elements
const timeline = document.getElementById("timeline");
const loading = document.getElementById("loading");
const searchInput = document.getElementById("searchInput");
const clearSearch = document.getElementById("clearSearch");
const noResults = document.getElementById("noResults");
const advancedToggle = document.getElementById("advancedToggle");
const advancedPanel = document.getElementById("advancedPanel");
const advancedBadge = document.getElementById("advancedBadge");
const filterMedia = document.getElementById("filterMedia");
const filterFrom = document.getElementById("filterFrom");
const filterUntil = document.getElementById("filterUntil");
const filterSummary = document.getElementById("filterSummary");
const resetFilters = document.getElementById("resetFilters");

// Join URL pieces
function join_url(first, second) {
  return `${first.replace(/\/+$/, '')}/${second.replace(/^\/+/, '')}`;
}

// Parse timestamp string in format "Mon Nov 03 20:07:11 +0000 2025"
function parseTimestamp(timestampStr) {
    // Parse format: "Day Mon DD HH:MM:SS +0000 YYYY"
    const parts = timestampStr.split(' ');
    const monthMap = {
        'Jan': 0, 'Feb': 1, 'Mar': 2, 'Apr': 3, 'May': 4, 'Jun': 5,
        'Jul': 6, 'Aug': 7, 'Sep': 8, 'Oct': 9, 'Nov': 10, 'Dec': 11
    };
    
    const month = monthMap[parts[1]];
    const day = parseInt(parts[2]);
    const timeParts = parts[3].split(':');
    const hours = parseInt(timeParts[0]);
    const minutes = parseInt(timeParts[1]);
    const seconds = parseInt(timeParts[2]);
    const year = parseInt(parts[5]);
    
    return new Date(year, month, day, hours, minutes, seconds);
}

// Format date
function formatDate(date) {
    const now = new Date();
    const diffMs = now - date;
    const diffSec = Math.floor(diffMs / 1000);
    const diffMin = Math.floor(diffSec / 60);
    const diffHour = Math.floor(diffMin / 60);
    const diffDay = Math.floor(diffHour / 24);

    if (diffSec < 60) return `${diffSec}s`;
    if (diffMin < 60) return `${diffMin}m`;
    if (diffHour < 24) return `${diffHour}h`;
    if (diffDay < 7) return `${diffDay}d`;
    
    return date.toLocaleDateString('en-US', { month: 'short', day: 'numeric' });
}

// Format full timestamp for hover text
function formatFullTimestamp(date) {
    return date.toLocaleString('en-US', { 
        hour: 'numeric',
        minute: '2-digit',
        hour12: true,
        month: 'short',
        day: 'numeric',
        year: 'numeric'
    });
}

// Load posts from JSON file
async function loadPostsData() {
    try {
        const response = await fetch('posts.json');
        if (!response.ok) {
            throw new Error('Failed to load posts');
        }
        const data = await response.json();
        
        // Convert timestamp strings to Date objects using parseTimestamp
        allPosts = data.map(post => ({
            ...post,
            timestamp: parseTimestamp(post.timestamp)
        }));
        
        filteredPosts = [...allPosts];
        
        // Check if there's a hash in the URL
        
        // Normal initialization without anchor
        loadPosts();
        observer.observe(loading);
        
    } catch (error) {
        console.error('Error loading posts:', error);
        timeline.innerHTML = '<div class="no-results"><p>Failed to load posts. Please try again later.</p></div>';
    }
}

// Format number (e.g., 1234 -> 1.2K)
function formatNumber(num) {
    if (num >= 1000000) return (num / 1000000).toFixed(1) + 'M';
    if (num >= 1000) return (num / 1000).toFixed(1) + 'K';
    return num.toString();
}

// Highlight search terms
function highlightText(text, query) {
    if (!query) return text;
    const regex = new RegExp(`(${query})`, 'gi');
    return text.replace(regex, '<span class="highlight">$1</span>');
}

 // Create post HTML using Mustache
function createPostHTML(post) {
    // 1. Process Content (Highlighting)
    let processedContent = post.content;
    processedContent = highlightText(processedContent, searchQuery);

    // 2. Process Media for Mustache (adding booleans for logic-less rendering)
    const hasMedia = post.media && post.media.length > 0;
    const mediaGridClass = hasMedia && post.media.length > 1 ? `grid-${post.media.length}` : '';
   
    let processedMedia = [];
    if (hasMedia) {
        processedMedia = post.media.map(media => ({
            ...media,
            media_url: media.media_url,
            is_image: media.type === 'image' || media.type !== 'video', // Fallback to image
            is_video: media.type === 'video'
        }));
    }

    // 3. Construct the View Model
    // We spread the original post object (...) to grab properties like id, handle, link, etc.,
    // and then add our computed/formatted properties on top.
    const viewData = {
        ...post,
        twitter_host: twitter_host, // Edit this if you used a custom twitter host in parse.rb
        base_url: base_url,
        avatar_url: post.avatar ? joinUrl(baseUrl, post.avatar) : null,
        post_url: join_url(join_url(base_url, 'post'), post['id']+'.html'),
        link: post.link,
        author_short: post.author ? post.author.slice(0, 3) : '',
        full_timestamp: formatFullTimestamp(post.timestamp),
        formatted_date: formatDate(post.timestamp),
        processedContent: processedContent,
        has_media: hasMedia,
        media_grid_class: mediaGridClass,
        media: processedMedia, // Overrides the raw post.media array
        formatted_retweets: formatNumber(post.retweets),
        formatted_likes: formatNumber(post.likes)
    };

    // 4. Render the Template
    return Mustache.render(POST_TEMPLATE, viewData);
}

// Load posts
function loadPosts() {
    if (isLoading) return;
    
    const postsToShow = filteredPosts.slice(currentIndex, currentIndex + POSTS_PER_PAGE);
    
    if (postsToShow.length === 0) {
        if (currentIndex === 0 && (searchQuery || advancedFiltersActive())) {
            noResults.style.display = 'block';
        }
        loading.style.display = 'none';
        return;
    }
    
    isLoading = true;
    loading.style.display = 'block';
    noResults.style.display = 'none';
    
    // Simulate network delay
    const token = loadToken;
    setTimeout(() => {
        // The filters changed while we were waiting, this page is stale
        if (token !== loadToken) return;

        postsToShow.forEach(post => {
            timeline.insertAdjacentHTML('beforeend', createPostHTML(post));
        });
        
        currentIndex += postsToShow.length;
        isLoading = false;
        
        // Hide loading if no more posts, otherwise keep it visible for intersection observer
        if (currentIndex >= filteredPosts.length) {
            loading.style.display = 'none';
        } else {
            loading.style.display = 'block';
        }
    }, 500);
}

// Parse a "YYYY-MM-DD" value from a date input into a local Date.
// Returns null for an empty or malformed value, so a half typed date
// doesn't wipe out the timeline.
function parseDateInput(value, endOfDay) {
    if (!value) return null;

    const parts = value.split('-');
    if (parts.length !== 3) return null;

    const year = parseInt(parts[0], 10);
    const month = parseInt(parts[1], 10) - 1;
    const day = parseInt(parts[2], 10);
    if (isNaN(year) || isNaN(month) || isNaN(day)) return null;

    return endOfDay
        ? new Date(year, month, day, 23, 59, 59, 999)
        : new Date(year, month, day, 0, 0, 0, 0);
}

// Does a post match the text in the search bar?
function matchesQuery(post) {
    if (!searchQuery) return true;

    return post.content.toLowerCase().includes(searchQuery) ||
           post.author.toLowerCase().includes(searchQuery) ||
           post.handle.toLowerCase().includes(searchQuery);
}

function hasMedia(post) {
    return Boolean(post.media && post.media.length > 0);
}

function advancedFiltersActive() {
    return mediaOnly || fromDate !== null || untilDate !== null;
}

// Update the "N posts" line and the dot on the Advanced search button
function updateFilterSummary() {
    const active = advancedFiltersActive();

    advancedBadge.style.display = active ? 'inline-block' : 'none';

    if (!active && !searchQuery) {
        filterSummary.textContent = '';
        return;
    }

    const count = filteredPosts.length;
    filterSummary.textContent = `${count} ${count === 1 ? 'post' : 'posts'} found`;
}

// Apply the search query and every advanced filter, then redraw the timeline
function applyFilters() {
    filteredPosts = allPosts.filter(post => {
        if (!matchesQuery(post)) return false;
        if (mediaOnly && !hasMedia(post)) return false;
        if (fromDate && post.timestamp < fromDate) return false;
        if (untilDate && post.timestamp > untilDate) return false;
        return true;
    });

    // Reset timeline
    loadToken += 1;
    isLoading = false;
    timeline.innerHTML = '';
    currentIndex = 0;
    noResults.style.display = 'none';
    updateFilterSummary();
    loadPosts();

    // Show/hide clear button
    clearSearch.style.display = searchQuery ? 'block' : 'none';
}

// Search posts
function searchPosts(query) {
    searchQuery = query.toLowerCase().trim();
    applyFilters();
}

// Read the advanced panel back into our filter state
function readAdvancedFilters() {
    mediaOnly = filterMedia.checked;
    fromDate = parseDateInput(filterFrom.value, false);
    untilDate = parseDateInput(filterUntil.value, true);

    // A backwards range would silently show nothing, so keep the inputs honest
    filterFrom.max = filterUntil.value || '';
    filterUntil.min = filterFrom.value || '';

    applyFilters();
}

// Debounce function
function debounce(func, wait) {
    let timeout;
    return function executedFunction(...args) {
        const later = () => {
            clearTimeout(timeout);
            func(...args);
        };
        clearTimeout(timeout);
        timeout = setTimeout(later, wait);
    };
}

// Intersection Observer for lazy loading
const observer = new IntersectionObserver((entries) => {
    entries.forEach(entry => {
        if (entry.isIntersecting && !isLoading && currentIndex < filteredPosts.length) {
            loadPosts();
        }
    });
}, {
    rootMargin: '100px'
});

// Event listeners
searchInput.addEventListener('input', debounce((e) => {
    searchPosts(e.target.value);
}, 300));

clearSearch.addEventListener('click', () => {
    searchInput.value = '';
    searchPosts('');
    searchInput.focus();
});

advancedToggle.addEventListener('click', () => {
    const isOpen = advancedPanel.style.display === 'block';
    advancedPanel.style.display = isOpen ? 'none' : 'block';
    advancedToggle.setAttribute('aria-expanded', String(!isOpen));
    advancedToggle.classList.toggle('open', !isOpen);
});

filterMedia.addEventListener('change', readAdvancedFilters);
filterFrom.addEventListener('change', readAdvancedFilters);
filterUntil.addEventListener('change', readAdvancedFilters);

resetFilters.addEventListener('click', () => {
    filterMedia.checked = false;
    filterFrom.value = '';
    filterUntil.value = '';
    readAdvancedFilters();
});

// Initialize - load posts from JSON file
loadPostsData();
