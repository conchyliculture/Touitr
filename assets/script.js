// Data
let allPosts = [];

// Configuration
const POSTS_PER_PAGE = 5;
let currentIndex = 0;
let isLoading = false;
let searchQuery = "";
let filteredPosts = [];

// DOM elements
const timeline = document.getElementById("timeline");
const loading = document.getElementById("loading");
const searchInput = document.getElementById("searchInput");
const clearSearch = document.getElementById("clearSearch");
const noResults = document.getElementById("noResults");

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
        
        // Initialize the timeline once data is loaded
        loadPosts();
        observer.observe(loading);
        
        // Check if there's a hash in the URL and load posts until that post is visible
        if (window.location.hash) {
            const targetId = window.location.hash.replace('#post-', '');
            const targetIndex = allPosts.findIndex(p => p.id == targetId);
            
            if (targetIndex !== -1 && targetIndex >= POSTS_PER_PAGE) {
                // Load all posts up to and including the target
                const loadUntilTarget = () => {
                    if (currentIndex <= targetIndex) {
                        setTimeout(() => {
                            loadPosts();
                            if (currentIndex <= targetIndex && currentIndex < filteredPosts.length) {
                                loadUntilTarget();
                            } else {
                                // Scroll to the target post after a brief delay
                                setTimeout(() => {
                                    const targetPost = document.getElementById(window.location.hash.substring(1));
                                    if (targetPost) {
                                        targetPost.scrollIntoView({ behavior: 'smooth', block: 'center' });
                                        // Add highlight effect
                                        targetPost.style.backgroundColor = 'rgba(29, 155, 240, 0.1)';
                                        setTimeout(() => {
                                            targetPost.style.backgroundColor = '';
                                        }, 2000);
                                    }
                                }, 300);
                            }
                        }, 100);
                    }
                };
                loadUntilTarget();
            }
        }
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

// Convert URLs in text to clickable links
function linkifyText(text) {
    const urlRegex = /(https?:\/\/[^\s]+)/g;
    return text.replace(urlRegex, '<a href="$1" target="_blank" rel="noopener noreferrer">$1</a>');
}

// Create post HTML
function createPostHTML(post) {
    const mediaHTML = post.media ? `
        <div class="post-media">
            <div class="media-grid ${post.media.length > 1 ? `grid-${post.media.length}` : ''}">
                ${post.media.map(url => `<img src="${url}" alt="Post media" loading="lazy">`).join('')}
            </div>
        </div>
    ` : '';

    const retweetHTML = post.isRetweet ? `
        <div class="retweet-indicator">
            <span class="retweet-icon">🔄</span>
            <span>${post.retweetedBy} Retweeted</span>
        </div>
    ` : '';

    const replyHTML = post.replyTo ? `
        <div class="reply-indicator">
            <span>💬 Replying to <a href="${post.replyTo}" class="reply-link">@${post.replyToAuthor}</a></span>
        </div>
    ` : '';

    const linkPreviewHTML = post.link ? `
        <a href="${post.link.url}" target="_blank" rel="noopener noreferrer" class="link-preview">
            ${post.link.image ? `<img src="${post.link.image}" alt="${post.link.title}" class="link-preview-image" loading="lazy">` : ''}
            <div class="link-preview-content">
                <div class="link-preview-domain">${post.link.domain}</div>
                <div class="link-preview-title">${post.link.title}</div>
                <div class="link-preview-description">${post.link.description}</div>
            </div>
        </a>
    ` : '';

    // First linkify URLs, then apply search highlighting
    // let processedContent = linkifyText(post.content);
    let processedContent = post.content;
    processedContent = highlightText(processedContent, searchQuery);

    return `
        <article class="post" id="post-${post.id}" data-post-id="${post.id}">
            ${retweetHTML}
            ${replyHTML}
            <div class="post-header">
                <img src="${post.avatar}" alt="${post.author.slice(0,3)}" class="avatar" loading="lazy">
                <div class="post-info">
                    <div class="post-author">
                        <span class="author-name">${post.author}</span>
                        <span class="author-handle">${post.handle}</span>
                        <span class="post-date-separator">·</span>
                        <a href="#post-${post.id}" class="post-date" title="${formatFullTimestamp(post.timestamp)}">${formatDate(post.timestamp)}</a>
                    </div>
                    <div class="post-content">${processedContent}</div>
                    ${linkPreviewHTML}
                    ${mediaHTML}
                    <div class="post-actions">
                        <div class="action-btn">
                            <span>💬</span>
                            <span>${formatNumber(post.replies)}</span>
                        </div>
                        <div class="action-btn">
                            <span>🔄</span>
                            <span>${formatNumber(post.retweets)}</span>
                        </div>
                        <div class="action-btn">
                            <span>❤️</span>
                            <span>${formatNumber(post.likes)}</span>
                        </div>
                        <div class="action-btn">
                            <span>📤</span>
                        </div>
                    </div>
                </div>
            </div>
        </article>
    `;
}

// Load posts
function loadPosts() {
    if (isLoading) return;
    
    const postsToShow = filteredPosts.slice(currentIndex, currentIndex + POSTS_PER_PAGE);
    
    if (postsToShow.length === 0) {
        if (currentIndex === 0 && searchQuery) {
            noResults.style.display = 'block';
        }
        loading.style.display = 'none';
        return;
    }
    
    isLoading = true;
    loading.style.display = 'block';
    noResults.style.display = 'none';
    
    // Simulate network delay
    setTimeout(() => {
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

// Search posts
function searchPosts(query) {
    searchQuery = query.toLowerCase().trim();
    
    if (searchQuery === "") {
        filteredPosts = [...allPosts];
    } else {
        filteredPosts = allPosts.filter(post => {
            return post.content.toLowerCase().includes(searchQuery) ||
                   post.author.toLowerCase().includes(searchQuery) ||
                   post.handle.toLowerCase().includes(searchQuery);
        });
    }
    
    // Reset timeline
    timeline.innerHTML = '';
    currentIndex = 0;
    loadPosts();
    
    // Show/hide clear button
    clearSearch.style.display = query ? 'block' : 'none';
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

// Initialize - load posts from JSON file
loadPostsData();
