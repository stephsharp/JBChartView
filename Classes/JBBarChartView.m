//
//  JBBarChartView.m
//  Nudge
//
//  Created by Terry Worona on 9/3/13.
//  Copyright (c) 2013 Jawbone. All rights reserved.
//

#import "JBBarChartView.h"

// Numerics
CGFloat static const kJBBarChartViewBarBasePaddingMutliplier = 50.0f;
CGFloat static const kJBBarChartViewUndefinedCachedHeight = -1.0f;
CGFloat static const kJBBarChartViewStateAnimationDuration = 0.17f;
CGFloat static const kJBBarChartViewReloadAnimationDuration = 0.2f;
CGFloat static const kJBBarChartViewStatePopOffset = 10.0f;
NSInteger static const kJBBarChartViewUndefinedBarIndex = -1;
NSInteger static const kJBBarChartViewDataLabelHeight = 21;

// Colors (JBChartView)
static UIColor *kJBBarChartViewDefaultBarColor = nil;

@interface JBChartView (Private)

- (BOOL)hasMaximumValue;
- (BOOL)hasMinimumValue;

@end

@interface JBBarChartView ()

@property (nonatomic, strong) NSDictionary *chartDataDictionary; // key = column, value = height
@property (nonatomic, strong) NSArray *barViews;
@property (nonatomic, strong) NSArray *dataLabels;
@property (nonatomic, strong) NSArray *cachedBarViewHeights;
@property (nonatomic, strong) NSArray *cachedDataLabelValues;
@property (nonatomic, assign) CGFloat barPadding;
@property (nonatomic, assign) CGFloat cachedMaxHeight;
@property (nonatomic, assign) CGFloat cachedMinHeight;
@property (nonatomic, strong) JBChartVerticalSelectionView *verticalSelectionView;
@property (nonatomic, assign) BOOL verticalSelectionViewVisible;
@property (nonatomic) NSNumberFormatter *percentageFormatter;

// Initialization
- (void)construct;

// View quick accessors
- (CGFloat)availableHeight;
- (CGFloat)normalizedHeightForRawHeight:(NSNumber*)rawHeight;
- (CGFloat)barWidth;

// Touch helpers
- (NSInteger)barViewIndexForPoint:(CGPoint)point;
- (UIView *)barViewForForPoint:(CGPoint)point;
- (void)touchesBeganOrMovedWithTouches:(NSSet *)touches;
- (void)touchesEndedOrCancelledWithTouches:(NSSet *)touches;

// Setters
- (void)setVerticalSelectionViewVisible:(BOOL)verticalSelectionViewVisible animated:(BOOL)animated;

@end

@implementation JBBarChartView

#pragma mark - Alloc/Init

+ (void)initialize
{
	if (self == [JBBarChartView class])
	{
		kJBBarChartViewDefaultBarColor = [UIColor blackColor];
	}
}

- (id)initWithCoder:(NSCoder *)aDecoder
{
    self = [super initWithCoder:aDecoder];
    if (self)
    {
        [self construct];
    }
    return self;
}

- (id)initWithFrame:(CGRect)frame
{
    self = [super initWithFrame:frame];
    if (self)
    {
        [self construct];
    }
    return self;
}

- (id)init
{
    self = [super init];
    if (self)
    {
        [self construct];
    }
    return self;
}

- (void)construct
{
    _showsVerticalSelection = YES;
    _cachedMinHeight = kJBBarChartViewUndefinedCachedHeight;
    _cachedMaxHeight = kJBBarChartViewUndefinedCachedHeight;
}

#pragma mark - Memory Management

- (void)dealloc
{
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
}

#pragma mark - Data

- (void)reloadData
{
    [self reloadDataAnimated:NO];
}

- (void)reloadDataAnimated:(BOOL)animated
{
    // reset cached max height
    self.cachedMinHeight = kJBBarChartViewUndefinedCachedHeight;
    self.cachedMaxHeight = kJBBarChartViewUndefinedCachedHeight;
    
    /*
     * The data collection holds all position information:
     * constructed via datasource and delegate functions
     */
    dispatch_block_t createDataDictionaries = ^{
        
        // Grab the count
        NSAssert([self.dataSource respondsToSelector:@selector(numberOfBarsInBarChartView:)], @"JBBarChartView // datasource must implement - (NSUInteger)numberOfBarsInBarChartView:(JBBarChartView *)barChartView");
        NSUInteger dataCount = [self.dataSource numberOfBarsInBarChartView:self];

        // Build up the data collection
        NSAssert([self.delegate respondsToSelector:@selector(barChartView:heightForBarViewAtIndex:)], @"JBBarChartView // delegate must implement - (CGFloat)barChartView:(JBBarChartView *)barChartView heightForBarViewAtIndex:(NSUInteger)index");
        NSMutableDictionary *dataDictionary = [NSMutableDictionary dictionary];
        for (NSUInteger index=0; index<dataCount; index++)
        {
            CGFloat height = [self.delegate barChartView:self heightForBarViewAtIndex:index];
            NSAssert(height >= 0, @"JBBarChartView // datasource function - (CGFloat)barChartView:(JBBarChartView *)barChartView heightForBarViewAtIndex:(NSUInteger)index must return a CGFloat >= 0");
            [dataDictionary setObject:[NSNumber numberWithFloat:height] forKey:[NSNumber numberWithInt:(int)index]];
        }
        self.chartDataDictionary = [NSDictionary dictionaryWithDictionary:dataDictionary];
	};
    
    /*
     * Determines the padding between bars as a function of # of bars
     */
    dispatch_block_t createBarPadding = ^{
        if ([self.delegate respondsToSelector:@selector(barPaddingForBarChartView:)])
        {
            self.barPadding = [self.delegate barPaddingForBarChartView:self];
        }
        else
        {
            NSUInteger totalBars = [[self.chartDataDictionary allKeys] count];
            self.barPadding = (1/(float)totalBars) * kJBBarChartViewBarBasePaddingMutliplier;
        }
    };
    
    /*
     * Creates a new bar graph view using the previously calculated data model
     */
    dispatch_block_t createBars = ^{
        
        // Remove old bars
        for (UIView *barView in self.barViews)
        {
            [barView removeFromSuperview];
        }

        // Remove old data labels
        if (self.showDataLabels)
        {
            for (UIView *dataLabelContainer in self.dataLabels)
            {
                [dataLabelContainer removeFromSuperview];
            }
        }

        if (!animated)
        {
            self.cachedBarViewHeights = nil;
            self.cachedDataLabelValues = nil;
        }
        
        CGFloat xOffset = 0;
        NSUInteger index = 0;
        NSMutableArray *mutableBarViews = [NSMutableArray array];
        NSMutableArray *mutableDataLabelViews = [NSMutableArray array];
        NSMutableArray *mutableCachedBarViewHeights = [NSMutableArray array];
        NSMutableArray *mutableCachedDataLabelValues = [NSMutableArray array];
        for (NSNumber *key in [[self.chartDataDictionary allKeys] sortedArrayUsingSelector:@selector(compare:)])
        {
            UIView *barView = nil; // since all bars are visible at once, no need to cache this view
            if ([self.dataSource respondsToSelector:@selector(barChartView:barViewAtIndex:)])
            {
                barView = [self.dataSource barChartView:self barViewAtIndex:index];
                NSAssert(barView != nil, @"JBBarChartView // datasource function - (UIView *)barChartView:(JBBarChartView *)barChartView barViewAtIndex:(NSUInteger)index must return a non-nil UIView subclass");
            }
            else
            {
                barView = [[UIView alloc] init];
                UIColor *backgroundColor = nil;

                if ([self.delegate respondsToSelector:@selector(barChartView:colorForBarViewAtIndex:)])
                {
                    backgroundColor = [self.delegate barChartView:self colorForBarViewAtIndex:index];
                    NSAssert(backgroundColor != nil, @"JBBarChartView // delegate function - (UIColor *)barChartView:(JBBarChartView *)barChartView colorForBarViewAtIndex:(NSUInteger)index must return a non-nil UIColor");
                }
                else
                {
                    backgroundColor = kJBBarChartViewDefaultBarColor;
                }

                barView.backgroundColor = backgroundColor;
            }
            
            barView.tag = index;

            NSNumber *rawHeight = [self.chartDataDictionary objectForKey:key];
            CGFloat height = [self normalizedHeightForRawHeight:rawHeight];
            CGFloat initialHeight = height;

            if (animated) {
                initialHeight = [self.cachedBarViewHeights[index] floatValue];
            }

            barView.frame = CGRectMake(xOffset, self.bounds.size.height - initialHeight - self.footerView.frame.size.height, [self barWidth], initialHeight);
            [mutableBarViews addObject:barView];
            [mutableCachedBarViewHeights addObject:[NSNumber numberWithFloat:height]];
            [mutableCachedDataLabelValues addObject:rawHeight];

            // Add new bar
            if (self.footerView)
            {
                [self insertSubview:barView belowSubview:self.footerView];
            }
            else
            {
                [self addSubview:barView];
            }

            if (self.showDataLabels)
            {
                UILabel *dataLabel;
                if (animated) {
                    dataLabel = [self dataLabelWithValue:self.cachedDataLabelValues[index]];
                }
                else {
                    dataLabel = [self dataLabelWithValue:rawHeight];
                }
                UIView *dataLabelContainer = [self dataLabelContainerWithLabel:dataLabel forBarView:barView];
                [self addSubview:dataLabelContainer];
                [mutableDataLabelViews addObject:dataLabelContainer];
            }

            if (animated) {
                CGFloat changeInHeight = height - initialHeight;

                [UIView animateWithDuration:kJBBarChartViewReloadAnimationDuration animations:^{
                    CGRect tempFrame = barView.frame;
                    tempFrame.size.height += changeInHeight;
                    tempFrame.origin.y -= changeInHeight;
                    barView.frame = tempFrame;
                }];

                if (self.showDataLabels) {
                    UIView *dataLabelContainer = mutableDataLabelViews[index];

                    [UIView animateWithDuration:kJBBarChartViewReloadAnimationDuration animations:^{
                        CGRect tempFrame = dataLabelContainer.frame;
                        tempFrame.origin.y -= changeInHeight;
                        dataLabelContainer.frame = tempFrame;
                    }];

                    // CA disregards the transition if it's in the same run loop as adding the subviews
                    // See: http://andrewmarinov.com/working-with-uiviews-transition-animations/
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.01 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        UILabel *dataLabel = dataLabelContainer.subviews[0];
                        [UIView transitionWithView:dataLabel
                                          duration:kJBBarChartViewReloadAnimationDuration
                                           options:UIViewAnimationOptionTransitionCrossDissolve
                                        animations:^{
                                            dataLabel.text = [self formattedDataLabelTextWithRawValue:rawHeight];
                                        } completion:nil];
                    });
                }
            }
            
            xOffset += ([self barWidth] + self.barPadding);
            index++;
        }
        self.barViews = [NSArray arrayWithArray:mutableBarViews];
        self.dataLabels = [NSArray arrayWithArray:mutableDataLabelViews];
        self.cachedBarViewHeights = [NSArray arrayWithArray:mutableCachedBarViewHeights];
        self.cachedDataLabelValues = [NSArray arrayWithArray:mutableCachedDataLabelValues];
    };
    
    /*
     * Creates a vertical selection view for touch events
     */
    dispatch_block_t createSelectionView = ^{
        
        // Remove old selection bar
        if (self.verticalSelectionView)
        {
            [self.verticalSelectionView removeFromSuperview];
            self.verticalSelectionView = nil;
        }
        
        CGFloat verticalSelectionViewHeight = self.bounds.size.height - self.headerView.frame.size.height - self.footerView.frame.size.height - self.headerPadding - self.footerPadding;
        
        if ([self.dataSource respondsToSelector:@selector(shouldExtendSelectionViewIntoHeaderPaddingForChartView:)])
        {
            if ([self.dataSource shouldExtendSelectionViewIntoHeaderPaddingForChartView:self])
            {
                verticalSelectionViewHeight += self.headerPadding;
            }
        }
        
        if ([self.dataSource respondsToSelector:@selector(shouldExtendSelectionViewIntoFooterPaddingForChartView:)])
        {
            if ([self.dataSource shouldExtendSelectionViewIntoFooterPaddingForChartView:self])
            {
                verticalSelectionViewHeight += self.footerPadding;
            }
        }

        self.verticalSelectionView = [[JBChartVerticalSelectionView alloc] initWithFrame:CGRectMake(0, 0, [self barWidth], verticalSelectionViewHeight)];
        self.verticalSelectionView.alpha = 0.0;
        self.verticalSelectionView.hidden = !self.showsVerticalSelection;
        if ([self.delegate respondsToSelector:@selector(barSelectionColorForBarChartView:)])
        {
            UIColor *selectionViewBackgroundColor = [self.delegate barSelectionColorForBarChartView:self];
            NSAssert(selectionViewBackgroundColor != nil, @"JBBarChartView // delegate function - (UIColor *)barSelectionColorForBarChartView:(JBBarChartView *)barChartView must return a non-nil UIColor");
            self.verticalSelectionView.bgColor = selectionViewBackgroundColor;
        }
        
        // Add new selection bar
        if (self.footerView)
        {
            [self insertSubview:self.verticalSelectionView belowSubview:self.footerView];
        }
        else
        {
            [self addSubview:self.verticalSelectionView];
        }
        
        self.verticalSelectionView.transform = self.inverted ? CGAffineTransformMakeScale(1.0, -1.0) : CGAffineTransformIdentity;
    };
    
    createDataDictionaries();
    createBarPadding();
    createBars();
    createSelectionView();
    
    // Position header and footer
    self.headerView.frame = CGRectMake(self.bounds.origin.x, self.bounds.origin.y, self.bounds.size.width, self.headerView.frame.size.height);
    self.footerView.frame = CGRectMake(self.bounds.origin.x, self.bounds.size.height - self.footerView.frame.size.height, self.bounds.size.width, self.footerView.frame.size.height);

    // Refresh state
    [self setState:self.state animated:NO force:YES callback:nil];
}

#pragma mark - Data labels

- (UILabel *)dataLabelWithValue:(NSNumber *)value
{
    UILabel *dataLabel = [[UILabel alloc] init];
    dataLabel.text = [self formattedDataLabelTextWithRawValue:value];
    dataLabel.font = [UIFont systemFontOfSize:17];
    dataLabel.textAlignment = NSTextAlignmentCenter;
    dataLabel.textColor = [UIColor colorWithRed:148/255.0f green:148/255.0f blue:148/255.0f alpha:1.0f];
    [dataLabel sizeToFit];

    return dataLabel;
}

- (UIView *)dataLabelContainerWithLabel:(UILabel *)dataLabel forBarView:(UIView *)barView
{
    // Increase width of data label to bar view width
    CGRect frame = dataLabel.frame;
    frame.size.width = barView.frame.size.width;
    frame.size.height = kJBBarChartViewDataLabelHeight;
    dataLabel.frame = frame;

    NSUInteger verticalPadding = 5;
    NSUInteger top = CGRectGetMinY(barView.frame);

    UIView *labelContainer = [[UIView alloc] initWithFrame:dataLabel.frame];
    labelContainer.center = CGPointMake(CGRectGetMidX(barView.frame), top - CGRectGetMidY(labelContainer.bounds) - verticalPadding);

    [labelContainer addSubview:dataLabel];

    return labelContainer;
}

- (void)toggleDataLabelText:(BOOL)showPercentages
{
    NSInteger index = 0;
    for (UIView *dataLabelContainer in self.dataLabels) {
        UILabel *dataLabel = dataLabelContainer.subviews[0];

        [UIView transitionWithView:dataLabel
                          duration:kJBBarChartViewReloadAnimationDuration
                           options:UIViewAnimationOptionTransitionCrossDissolve
                        animations:^{
                            dataLabel.text = [self formattedDataLabelTextWithRawValue:self.cachedDataLabelValues[index]];
                        } completion:nil];

        index += 1;
    }
}

- (NSString *)formattedDataLabelTextWithRawValue:(NSNumber *)value
{
    if (self.showDataLabelsAsPercentages) {
        NSUInteger total = [self dataLabelsTotal];

        if (total > 0) {
            float percentage = [value floatValue] / total;
            return [self.percentageFormatter stringFromNumber:[NSNumber numberWithFloat:percentage]];
        }
    }

    return [value stringValue];
}

- (NSUInteger)dataLabelsTotal
{
    NSUInteger total = 0;
    for (NSNumber *value in self.cachedDataLabelValues) {
        total += [value integerValue];
    }
    return total;
}

#pragma mark - View Quick Accessors

- (CGFloat)availableHeight
{
    CGFloat availableHeight = self.bounds.size.height - self.headerView.frame.size.height - self.footerView.frame.size.height - self.headerPadding - self.footerPadding;

    if (self.showDataLabels) {
        availableHeight -= kJBBarChartViewDataLabelHeight;
    }

    return availableHeight;
}

- (CGFloat)normalizedHeightForRawHeight:(NSNumber*)rawHeight
{
    CGFloat minHeight = [self minimumValue];
    CGFloat maxHeight = [self maximumValue];
    CGFloat value = [rawHeight floatValue];
    
    if ((maxHeight - minHeight) <= 0)
    {
        return 0;
    }
    
    return ((value - minHeight) / (maxHeight - minHeight)) * [self availableHeight];
}

- (CGFloat)barWidth
{
    NSUInteger barCount = [[self.chartDataDictionary allKeys] count];
    if (barCount > 0)
    {
        CGFloat totalPadding = (barCount - 1) * self.barPadding;
        CGFloat availableWidth = self.bounds.size.width - totalPadding;
        return availableWidth / barCount;
    }
    return 0;
}

#pragma mark - Setters

- (void)setState:(JBChartViewState)state animated:(BOOL)animated force:(BOOL)force callback:(void (^)())callback
{
    [super setState:state animated:animated force:force callback:callback];
    
    __weak JBBarChartView* weakSelf = self;
    
    void (^updateBarView)(UIView *barView, BOOL popBar);
    
    updateBarView = ^(UIView *barView, BOOL popBar) {
        if (weakSelf.inverted)
        {
            if (weakSelf.state == JBChartViewStateExpanded)
            {
                if (popBar)
                {
                    barView.frame = CGRectMake(barView.frame.origin.x, weakSelf.headerView.frame.size.height + weakSelf.headerPadding, barView.frame.size.width, [[weakSelf.cachedBarViewHeights objectAtIndex:barView.tag] floatValue] + kJBBarChartViewStatePopOffset);
                }
                else
                {
                    barView.frame = CGRectMake(barView.frame.origin.x, weakSelf.headerView.frame.size.height + weakSelf.headerPadding, barView.frame.size.width, [[weakSelf.cachedBarViewHeights objectAtIndex:barView.tag] floatValue]);
                }
            }
            else if (weakSelf.state == JBChartViewStateCollapsed)
            {
                if (popBar)
                {
                    barView.frame = CGRectMake(barView.frame.origin.x, weakSelf.headerView.frame.size.height + weakSelf.headerPadding, barView.frame.size.width, [[weakSelf.cachedBarViewHeights objectAtIndex:barView.tag] floatValue] + kJBBarChartViewStatePopOffset);
                }
                else
                {
                    barView.frame = CGRectMake(barView.frame.origin.x, weakSelf.headerView.frame.size.height + weakSelf.headerPadding, barView.frame.size.width, 0.0f);
                }
            }
        }
        else
        {
            if (weakSelf.state == JBChartViewStateExpanded)
            {
                if (popBar)
                {
                    barView.frame = CGRectMake(barView.frame.origin.x, weakSelf.bounds.size.height - weakSelf.footerView.frame.size.height - weakSelf.footerPadding - [[weakSelf.cachedBarViewHeights objectAtIndex:barView.tag] floatValue] - kJBBarChartViewStatePopOffset, barView.frame.size.width, [[weakSelf.cachedBarViewHeights objectAtIndex:barView.tag] floatValue] + kJBBarChartViewStatePopOffset);
                }
                else
                {
                    barView.frame = CGRectMake(barView.frame.origin.x, weakSelf.bounds.size.height - weakSelf.footerView.frame.size.height - weakSelf.footerPadding - [[weakSelf.cachedBarViewHeights objectAtIndex:barView.tag] floatValue], barView.frame.size.width, [[weakSelf.cachedBarViewHeights objectAtIndex:barView.tag] floatValue]);

                    if (self.barViews.count > 0 && self.dataLabels.count == self.barViews.count) {
                        NSUInteger barViewIndex = [self.barViews indexOfObject:barView];
                        ((UIView *)self.dataLabels[barViewIndex]).alpha = 1.0f;
                    }
                }
            }
            else if (weakSelf.state == JBChartViewStateCollapsed)
            {
                if (popBar)
                {
                    barView.frame = CGRectMake(barView.frame.origin.x, weakSelf.bounds.size.height - weakSelf.footerView.frame.size.height - weakSelf.footerPadding - [[weakSelf.cachedBarViewHeights objectAtIndex:barView.tag] floatValue] - kJBBarChartViewStatePopOffset, barView.frame.size.width, [[weakSelf.cachedBarViewHeights objectAtIndex:barView.tag] floatValue] + kJBBarChartViewStatePopOffset);
                }
                else
                {
                    barView.frame = CGRectMake(barView.frame.origin.x, weakSelf.bounds.size.height, barView.frame.size.width, 0.0f);

                    if (self.barViews.count > 0 && self.dataLabels.count == self.barViews.count) {
                        NSUInteger barViewIndex = [self.barViews indexOfObject:barView];
                        ((UIView *)self.dataLabels[barViewIndex]).alpha = 0.0f;
                    }

                }
            }
        }
    };
    
    dispatch_block_t callbackCopy = [callback copy];
    
    if ([self.barViews count] > 0)
    {
        if (animated)
        {
            NSUInteger index = 0;
            for (UIView *barView in self.barViews)
            {
                // If height is 0, don't pop bar
                BOOL popBar = [self.cachedDataLabelValues[index] integerValue] ? YES : NO;

                NSUInteger expandOrder = [self expandOrderForIndex:index];
                NSTimeInterval delay = (kJBBarChartViewStateAnimationDuration * 1) * expandOrder;

                [UIView animateWithDuration:kJBBarChartViewStateAnimationDuration delay:delay options:UIViewAnimationOptionBeginFromCurrentState animations:^{
                    updateBarView(barView, popBar);
                } completion:^(BOOL finished) {
                    [UIView animateWithDuration:kJBBarChartViewStateAnimationDuration delay:0.0 options:UIViewAnimationOptionBeginFromCurrentState animations:^{
                        updateBarView(barView, NO);
                    } completion:^(BOOL lastBarFinished) {
                        if ((NSUInteger)barView.tag == [self.barViews count] - 1)
                        {
                            if (callbackCopy)
                            {
                                callbackCopy();
                            }
                        }
                    }];
                }];
                index++;
            }
        }
        else
        {
            for (UIView *barView in self.barViews)
            {
                updateBarView(barView, NO);
            }
            if (callbackCopy)
            {
                callbackCopy();
            }
        }
    }
    else
    {
        if (callbackCopy)
        {
            callbackCopy();
        }
    }
}

- (NSUInteger)expandOrderForIndex:(NSUInteger)index
{
    BOOL useExpandOrder = (self.expandOrder && [self.expandOrder count] >= [self.barViews count]) ? YES : NO;

    if (useExpandOrder) {
        return [self.expandOrder[index] integerValue];
    }
    return index;
}

- (void)setState:(JBChartViewState)state animated:(BOOL)animated callback:(void (^)())callback
{
    [self setState:state animated:animated force:NO callback:callback];
}

- (void)setShowDataLabelsAsPercentages:(BOOL)showDataLabelsAsPercentages
{
    _showDataLabelsAsPercentages = showDataLabelsAsPercentages;
    [self toggleDataLabelText:_showDataLabelsAsPercentages];
}

#pragma mark - Getters

- (CGFloat)cachedMinHeight
{
    if(_cachedMinHeight == kJBBarChartViewUndefinedCachedHeight)
    {
        NSArray *chartValues = [[NSMutableArray arrayWithArray:[self.chartDataDictionary allValues]] sortedArrayUsingSelector:@selector(compare:)];
        _cachedMinHeight =  [[chartValues firstObject] floatValue];
    }
    return _cachedMinHeight;
}

- (CGFloat)cachedMaxHeight
{
    if (_cachedMaxHeight == kJBBarChartViewUndefinedCachedHeight)
    {
        NSArray *chartValues = [[NSMutableArray arrayWithArray:[self.chartDataDictionary allValues]] sortedArrayUsingSelector:@selector(compare:)];
        _cachedMaxHeight =  [[chartValues lastObject] floatValue];
    }
    return _cachedMaxHeight;
}

- (CGFloat)minimumValue
{
    if ([self hasMinimumValue])
    {
        return fminf(self.cachedMinHeight, [super minimumValue]);
    }
    return self.cachedMinHeight;
}

- (CGFloat)maximumValue
{
    if ([self hasMaximumValue])
    {
        return fmaxf(self.cachedMaxHeight, [super maximumValue]);
    }
    return self.cachedMaxHeight;    
}

- (NSNumberFormatter *)percentageFormatter
{
    if (!_percentageFormatter) {
        _percentageFormatter = [NSNumberFormatter new];
        _percentageFormatter.numberStyle = NSNumberFormatterPercentStyle;
        _percentageFormatter.maximumFractionDigits = 0;
    }
    return _percentageFormatter;
}

#pragma mark - Touch Helpers

- (NSInteger)barViewIndexForPoint:(CGPoint)point
{
    NSUInteger index = 0;
    NSUInteger selectedIndex = kJBBarChartViewUndefinedBarIndex;
    
    if (point.x < 0 || point.x > self.bounds.size.width)
    {
        return selectedIndex;
    }
    
    CGFloat padding = ceil(self.barPadding * 0.5);
    for (UIView *barView in self.barViews)
    {
        CGFloat minX = CGRectGetMinX(barView.frame) - padding;
        CGFloat maxX = CGRectGetMaxX(barView.frame) + padding;
        if ((point.x >= minX) && (point.x <= maxX))
        {
            selectedIndex = index;
            break;
        }
        index++;
    }
    return selectedIndex;
}

- (UIView *)barViewForForPoint:(CGPoint)point
{
    UIView *barView = nil;
    NSInteger selectedIndex = [self barViewIndexForPoint:point];
    if (selectedIndex >= 0)
    {
        return [self.barViews objectAtIndex:[self barViewIndexForPoint:point]];
    }
    return barView;
}

- (void)touchesBeganOrMovedWithTouches:(NSSet *)touches
{
    if (self.state == JBChartViewStateCollapsed || [[self.chartDataDictionary allKeys] count] <= 0)
    {
        return;
    }
    
    UITouch *touch = [touches anyObject];
    CGPoint touchPoint = [touch locationInView:self];
    UIView *barView = [self barViewForForPoint:touchPoint];
    if (barView == nil)
    {
        [self setVerticalSelectionViewVisible:NO animated:YES];
        return;
    }
    CGRect barViewFrame = barView.frame;
    CGRect selectionViewFrame = self.verticalSelectionView.frame;
    selectionViewFrame.origin.x = barViewFrame.origin.x;
    selectionViewFrame.size.width = barViewFrame.size.width;
    
    if ([self.dataSource respondsToSelector:@selector(shouldExtendSelectionViewIntoHeaderPaddingForChartView:)])
    {
        if ([self.dataSource shouldExtendSelectionViewIntoHeaderPaddingForChartView:self])
        {
            selectionViewFrame.origin.y = self.headerView.frame.size.height;
        }
        else
        {
            selectionViewFrame.origin.y = self.headerView.frame.size.height + self.headerPadding;
        }
    }
    else
    {
        selectionViewFrame.origin.y = self.headerView.frame.size.height + self.headerPadding;
    }
    
    self.verticalSelectionView.frame = selectionViewFrame;
    [self setVerticalSelectionViewVisible:YES animated:YES];
    
    if ([self.delegate respondsToSelector:@selector(barChartView:didSelectBarAtIndex:touchPoint:)])
    {
        [self.delegate barChartView:self didSelectBarAtIndex:[self barViewIndexForPoint:touchPoint] touchPoint:touchPoint];
    }
    
    if ([self.delegate respondsToSelector:@selector(barChartView:didSelectBarAtIndex:)])
    {
        [self.delegate barChartView:self didSelectBarAtIndex:[self barViewIndexForPoint:touchPoint]];
    }
}

- (void)touchesEndedOrCancelledWithTouches:(NSSet *)touches
{
    if (self.state == JBChartViewStateCollapsed || [[self.chartDataDictionary allKeys] count] <= 0)
    {
        return;
    }
    
    [self setVerticalSelectionViewVisible:NO animated:YES];
    
    if ([self.delegate respondsToSelector:@selector(didDeselectBarChartView:)])
    {
        [self.delegate didDeselectBarChartView:self];
    }
}

#pragma mark - Setters

- (void)setVerticalSelectionViewVisible:(BOOL)verticalSelectionViewVisible animated:(BOOL)animated
{
    _verticalSelectionViewVisible = verticalSelectionViewVisible;
    
    if (animated)
    {
        [UIView animateWithDuration:kJBChartViewDefaultAnimationDuration delay:0.0 options:UIViewAnimationOptionBeginFromCurrentState animations:^{
            self.verticalSelectionView.alpha = self.verticalSelectionViewVisible ? 1.0 : 0.0;
        } completion:nil];
    }
    else
    {
        self.verticalSelectionView.alpha = _verticalSelectionViewVisible ? 1.0 : 0.0;
    }
}

- (void)setVerticalSelectionViewVisible:(BOOL)verticalSelectionViewVisible
{
    [self setVerticalSelectionViewVisible:verticalSelectionViewVisible animated:NO];
}

- (void)setShowsVerticalSelection:(BOOL)showsVerticalSelection
{
    _showsVerticalSelection = showsVerticalSelection;
    self.verticalSelectionView.hidden = _showsVerticalSelection ? NO : YES;
}

#pragma mark - Touches

- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event
{
    [self touchesBeganOrMovedWithTouches:touches];
}

- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event
{
    [self touchesBeganOrMovedWithTouches:touches];
}

- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event
{
    [self touchesEndedOrCancelledWithTouches:touches];
}

- (void)touchesCancelled:(NSSet *)touches withEvent:(UIEvent *)event
{
    [self touchesEndedOrCancelledWithTouches:touches];
}

@end
